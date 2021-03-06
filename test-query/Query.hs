{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}

module Query (
    testSimpleOnePlusOne
  , testSimpleSelect
  , testSimpleParams
  , testSimpleInsertId
  , testSimpleMultiInsert
  , testSimpleQueryCov
  , testSimpleStrings
  , testSimpleChanges
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
-- orphan IsString instance in older byteString
import           Data.ByteString.Lazy.Char8 ()
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import Data.Tuple (Solo (..))

import           Common

#if !MIN_VERSION_base(4,11,0)
import Data.Monoid ((<>))
#endif

-- Simplest SELECT
testSimpleOnePlusOne :: TestEnv -> Test
testSimpleOnePlusOne TestEnv{..} = TestCase $ do
  rows <- query_ conn "SELECT 1+1" :: IO [Solo Int]
  assertEqual "row count" 1 (length rows)
  assertEqual "value" (Solo 2) (head rows)

testSimpleSelect :: TestEnv -> Test
testSimpleSelect TestEnv{..} = TestCase $ do
  execute_ conn "CREATE TABLE test1 (id INTEGER PRIMARY KEY, t TEXT)"
  execute_ conn "INSERT INTO test1 (t) VALUES ('test string')"
  rows <- query_ conn "SELECT t FROM test1" :: IO [Solo String]
  assertEqual "row count" 1 (length rows)
  assertEqual "string" (Solo "test string") (head rows)
  rows <- query_ conn "SELECT id,t FROM test1" :: IO [(Int, String)]
  assertEqual "int,string" (1, "test string") (head rows)
  -- Add another row
  execute_ conn "INSERT INTO test1 (t) VALUES ('test string 2')"
  rows <- query_ conn "SELECT id,t FROM test1" :: IO [(Int, String)]
  assertEqual "row count" 2 (length rows)
  assertEqual "int,string" (1, "test string") (rows !! 0)
  assertEqual "int,string" (2, "test string 2") (rows !! 1)
  [Solo r] <- query_ conn "SELECT NULL" :: IO [Solo (Maybe Int)]
  assertEqual "nulls" Nothing r
  [Solo r] <- query_ conn "SELECT 1" :: IO [Solo (Maybe Int)]
  assertEqual "nulls" (Just 1) r
  [Solo r] <- query_ conn "SELECT 1.0" :: IO [Solo Double]
  assertEqual "doubles" 1.0 r
  [Solo r] <- query_ conn "SELECT 1.0" :: IO [Solo Float]
  assertEqual "floats" 1.0 r

testSimpleParams :: TestEnv -> Test
testSimpleParams TestEnv{..} = TestCase $ do
  execute_ conn "CREATE TABLE testparams (id INTEGER PRIMARY KEY, t TEXT)"
  execute_ conn "CREATE TABLE testparams2 (id INTEGER, t TEXT, t2 TEXT)"
  [Solo i] <- query conn "SELECT ?" (Solo (42 :: Int))  :: IO [Solo Int]
  assertEqual "select int param" 42 i
  execute conn "INSERT INTO testparams (t) VALUES (?)" (Solo ("test string" :: String))
  rows <- query conn "SELECT t FROM testparams WHERE id = ?" (Solo (1 :: Int)) :: IO [Solo String]
  assertEqual "row count" 1 (length rows)
  assertEqual "string" (Solo "test string") (head rows)
  execute_ conn "INSERT INTO testparams (t) VALUES ('test2')"
  [Solo row] <- query conn "SELECT t FROM testparams WHERE id = ?" (Solo (1 :: Int)) :: IO [Solo String]
  assertEqual "select params" "test string" row
  [Solo row] <- query conn "SELECT t FROM testparams WHERE id = ?" (Solo (2 :: Int)) :: IO [Solo String]
  assertEqual "select params" "test2" row
  [Solo r1, Solo r2] <- query conn "SELECT t FROM testparams WHERE (id = ? OR id = ?)" (1 :: Int, 2 :: Int) :: IO [Solo String]
  assertEqual "select params" "test string" r1
  assertEqual "select params" "test2" r2
  [Solo i] <- query conn "SELECT ?+?" [42 :: Int, 1 :: Int] :: IO [Solo Int]
  assertEqual "select int param" 43 i
  [Solo d] <- query conn "SELECT ?" [2.0 :: Double] :: IO [Solo Double]
  assertEqual "select double param" 2.0 d
  [Solo f] <- query conn "SELECT ?" [4.0 :: Float] :: IO [Solo Float]
  assertEqual "select double param" 4.0 f

testSimpleInsertId :: TestEnv -> Test
testSimpleInsertId TestEnv{..} = TestCase $ do
  execute_ conn "CREATE TABLE test_row_id (id INTEGER PRIMARY KEY, t TEXT)"
  execute conn "INSERT INTO test_row_id (t) VALUES (?)" (Solo ("test string" :: String))
  id1 <- lastInsertRowId conn
  execute_ conn "INSERT INTO test_row_id (t) VALUES ('test2')"
  id2 <- lastInsertRowId conn
  1 @=? id1
  2 @=? id2
  rows <- query conn "SELECT t FROM test_row_id WHERE id = ?" (Solo (1 :: Int)) :: IO [Solo String]
  1 @=?  (length rows)
  (Solo "test string") @=? (head rows)
  [Solo row] <- query conn "SELECT t FROM test_row_id WHERE id = ?" (Solo (2 :: Int)) :: IO [Solo String]
  "test2" @=? row

testSimpleMultiInsert :: TestEnv -> Test
testSimpleMultiInsert TestEnv{..} = TestCase $ do
  execute_ conn "CREATE TABLE test_multi_insert (id INTEGER PRIMARY KEY, t1 TEXT, t2 TEXT)"
  executeMany conn "INSERT INTO test_multi_insert (t1, t2) VALUES (?, ?)" ([("foo", "bar"), ("baz", "bat")] :: [(String, String)])
  id2 <- lastInsertRowId conn
  2 @=? id2

  rows <- query_ conn "SELECT id,t1,t2 FROM test_multi_insert" :: IO [(Int, String, String)]
  [(1, "foo", "bar"), (2, "baz", "bat")] @=? rows

testSimpleQueryCov :: TestEnv -> Test
testSimpleQueryCov TestEnv{..} = TestCase $ do
  let str = "SELECT 1+1" :: T.Text
      q   = "SELECT 1+1" :: Query
  fromQuery q @=? str
  show str @=? show q
  q @=? ((read . show $ q) :: Query)
  q @=? q
  q @=? (Query "SELECT 1" <> Query "+1")
  q @=? foldr mappend mempty ["SELECT ", "1", "+", "1"]
  True @=? q <= q

testSimpleStrings :: TestEnv -> Test
testSimpleStrings TestEnv{..} = TestCase $ do
  [Solo s] <- query_ conn "SELECT 'str1'"  :: IO [Solo T.Text]
  s @=? "str1"
  [Solo s] <- query_ conn "SELECT 'strLazy'"  :: IO [Solo LT.Text]
  s @=? "strLazy"
  [Solo s] <- query conn "SELECT ?" (Solo ("strP" :: T.Text)) :: IO [Solo T.Text]
  s @=? "strP"
  [Solo s] <- query conn "SELECT ?" (Solo ("strPLazy" :: LT.Text)) :: IO [Solo T.Text]
  s @=? "strPLazy"
  -- ByteStrings are blobs in sqlite storage, so use ByteString for
  -- both input and output
  [Solo s] <- query conn "SELECT ?" (Solo ("strBsP" :: BS.ByteString)) :: IO [Solo BS.ByteString]
  s @=? "strBsP"
  [Solo s] <- query conn "SELECT ?" (Solo ("strBsPLazy" :: LBS.ByteString)) :: IO [Solo BS.ByteString]
  s @=? "strBsPLazy"
  [Solo s] <- query conn "SELECT ?" (Solo ("strBsPLazy2" :: BS.ByteString)) :: IO [Solo LBS.ByteString]
  s @=? "strBsPLazy2"

testSimpleChanges :: TestEnv -> Test
testSimpleChanges TestEnv{..} = TestCase $ do
  execute_ conn "CREATE TABLE testchanges (id INTEGER PRIMARY KEY, t TEXT)"
  execute conn "INSERT INTO testchanges(t) VALUES (?)" (Solo ("test string" :: String))
  numChanges <- changes conn
  assertEqual "changed/inserted rows" 1 numChanges
  execute conn "INSERT INTO testchanges(t) VALUES (?)" (Solo ("test string 2" :: String))
  numChanges <- changes conn
  assertEqual "changed/inserted rows" 1 numChanges
  execute_ conn "UPDATE testchanges SET t = 'foo' WHERE id = 1"
  numChanges <- changes conn
  assertEqual "changed/inserted rows" 1 numChanges
  execute_ conn "UPDATE testchanges SET t = 'foo' WHERE id = 100"
  numChanges <- changes conn
  assertEqual "changed/inserted rows" 0 numChanges
  execute_ conn "UPDATE testchanges SET t = 'foo'"
  numChanges <- changes conn
  assertEqual "changed/inserted rows" 2 numChanges
