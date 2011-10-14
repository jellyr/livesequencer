module Program where

import IO
import Term
import Rule

import Text.Parsec
import Text.PrettyPrint.HughesPJ
import qualified Data.Set as S
import Control.Monad ( guard )

data Program = Program 
               { rules :: [ Rule ] 
               , functions :: S.Set Identifier
               , constructors :: S.Set Identifier
               }

instance Input Program where
  input = do 
    rs <- many input 
    let fs = S.fromList $ do
          r <- rs 
          let Node f xs = lhs r
          return f    
        cs = S.fromList $ do  
          r <- rs
          (p, Node f xs) <- subterms ( rhs r )
          guard $ isConstructor f
          return f
    return $ Program { rules = rs, functions = fs, constructors = cs }
instance Output Program where 
  output p = vcat $ map output $ rules p
  
instance Show Program where show = render . output
instance Read Program where readsPrec = parsec_reader
  