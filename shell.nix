let
  myNixPkgs = import <nixpkgs> {};
in
myNixPkgs.mkShell {
  nativeBuildInputs = with myNixPkgs; [
    cabal-install 
    ghc 
    haskell-language-server
    ormolu
    sqlite
  ];
}
