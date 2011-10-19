module Term where

import IO
import Common ( void )

import qualified Text.ParserCombinators.Parsec.Token as T
import qualified Text.ParserCombinators.Parsec.Language as L
import Text.ParserCombinators.Parsec ( Parser )
import Text.Parsec as Parsec
import Text.Parsec.Expr
import Text.Parsec.Token ( reservedOp )
import Text.PrettyPrint.HughesPJ

import qualified Data.Set as S
import Control.Monad ( mzero )
import Data.Char (isUpper, isLower)

data Identifier =  
     Identifier { name :: String 
                , start :: SourcePos , end :: SourcePos
                }

instance Eq Identifier where
-- | FIXME: this is ignoring the module.
-- for a complete implementation, we'd need fully qualified names
    i == j = name i == name j

instance Ord Identifier where
    compare i j = compare ( name i ) ( name j )

isConstructor :: Identifier -> Bool
isConstructor i = isUpper $ head $ name i

isVariable :: Identifier -> Bool
isVariable i = isLower $ head $ name i



lexer :: T.TokenParser st
lexer =
   T.makeTokenParser $ L.emptyDef {
      L.commentStart = "{-",
      L.commentEnd = "-}",
      L.commentLine = "--",
      L.nestedComments = True,
      L.identStart = letter <|> Parsec.char '_',
      -- FIXME: check the distinction between '.' in qualified names, and as operator
      L.identLetter = alphaNum <|> Parsec.char '_' <|> Parsec.char '.' ,
      L.opStart = oneOf ":!#$%&*+./<=>?@\\^|-~" ,
      L.opLetter = oneOf ":!#$%&*+./<=>?@\\^|-~" ,
      L.caseSensitive = True ,
      L.reservedNames = [ "module", "where", "import", "qualified"
                        , "as", "data", "class", "instance", "case", "of" ] ,
      L.reservedOpNames = [ "=", "::", "|" ]
      }


-- FIXME: this should be read from a file (Prelude.hs).
-- but then we need a parser that correctly handles fixity information
-- on-the-fly. 
-- For now, we hard-code Prelude's fixities:
{-


infixr 9  .
infixr 8  ^, ^^, **
infixl 7  *, /, `quot`, `rem`, `div`, `mod`
infixl 6  +, -

-- The (:) operator is built-in syntax, and cannot legally be given
-- a fixity declaration; but its fixity is given by:
--   infixr 5  :

infix  4  ==, /=, <, <=, >=, >
infixr 3  &&
infixr 2  ||
infixl 1  >>, >>=
infixr 1  =<<
infixr 0  $, $!, `seq`
-}

operators = 
  [ [ ( ".", AssocRight ) ]
  , [ ( "^", AssocRight) ]
  , [ ( "*", AssocLeft), ("/", AssocLeft) ]  
  , [ ( "+", AssocLeft), ("-", AssocLeft) ] 
  , [ ( ":", AssocRight ) ]
  , map ( \ s -> (s, AssocNone) ) [ "==", "/=", "<", "<=", ">=", ">" ] 
  , [ ( "&&", AssocRight ) ]  
  , [ ( "||", AssocRight ) ]    
  ]

identifier :: Parser String
identifier = T.identifier lexer

symbol :: String -> Parser ()
symbol = void . T.symbol lexer


instance Input Identifier where
  input = do
      p <- getPosition
      x <- identifier
      -- FIXME: the identifier parser will also eat trailing whitespace
      -- so we get the wrong end position here:
      q <- getPosition
      return $ Identifier { name = x , start = p, end = q }

instance Output Identifier where
  output i = text $ name i

instance Show Identifier where show = render . output
instance Read Identifier where readsPrec = parsec_reader


data Term = Node Identifier [ Term ]
          | Number Integer  -- ^ FIXME: Number is missing source information
    deriving ( Eq, Ord )

instance Show Term where show = render . output
instance Read Term where readsPrec = parsec_reader


instance Input Term where
  input = let p atomic =
                     fmap Number (T.natural lexer)
                 <|> T.parens lexer input
                 <|> bracketed_list
                 <|> do f <- input ; args <- if atomic then return [] else many ( p True )
                        return $ Node f args
          in  buildExpressionParser table ( p False )

table = map ( map binary ) operators
binary (s, assoc) = flip Infix assoc $ do
  p <- getPosition
  reservedOp lexer s  
  q <- getPosition
  return $ \ l r -> Node ( Identifier { name = s, start = p, end = q } ) [ l, r ]


bracketed_list :: Parser Term
bracketed_list = do
    q <- getPosition ; symbol "[" ; r <- getPosition
    inside_bracketed_list q r

inside_bracketed_list :: SourcePos -> SourcePos -> Parser Term
inside_bracketed_list p p' =
        do q <- getPosition ; symbol "]" ; r <- getPosition
           return $ Node ( Identifier { name = "Nil", start = q, end = r } ) []
    <|> do x <- input
           q <- getPosition
           xs <-   do symbol "]" ; r <- getPosition
                      return $ Node ( Identifier { name = "Nil", start = q, end = r } ) []
               <|> do symbol "," ; r <- getPosition
                      inside_bracketed_list q r
           return $ Node ( Identifier { name = "Cons", start = p, end = p' } ) [ x, xs ]

instance Output Term where
  output t = case t of
     Number n -> text $ show n
     Node f args -> output f <+> fsep ( map protected args )

protected :: Term -> Doc
protected t = case t of
  Node _f (_:_) -> parens $ output t
  _ -> output t


type Position = [ Int ]

subterms :: Term -> [ (Position, Term) ]
subterms t = ( [], t ) : case t of
    Node _f xs -> do
        (k, x) <- zip [ 0.. ] xs
        (p, s) <- subterms x
        return (k : p, s)
    _ -> []

signature :: Term -> S.Set Identifier
signature t = S.fromList $ do
    (_p, Node f _xs) <- subterms t
    return f

peek :: Term -> Position -> Maybe Term
peek t [] = return t
peek (Node _f xs) (k : ks) | k < length xs =
    peek (xs !! k) ks
peek _ _  = mzero

poke :: Term -> Position -> Term -> Maybe Term
poke _t [] s = return s
poke (Node f xs) (k : ks) s | k < length xs = do
    let (pre, x : post) = splitAt k xs
    y <- poke x ks s
    return $ Node f $ pre ++ y : post
