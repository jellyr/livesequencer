module Function where

import Prelude ( Integer, Int, (-) )


infixr 9 . ;

(.) :: (b -> c) -> (a -> b) -> a -> c ;
(f . g) x = f (g x) ;

infixr 0 $ ;

($) :: (a -> b) -> a -> b ;
f $ x = f x ;

-- $!
applyStrict :: (Integer -> a) -> (Integer -> a) ;
applyStrict f 0 = f 0 ;
applyStrict f x = f x ;


flip :: (b -> a -> c) -> a -> b -> c ;
flip f x y = f y x ;

id :: a -> a ;
id x = x ;

nest :: Int -> (a -> a) -> a -> a ;
nest 0 _ x = x ;
nest n f x = nest (n-1) f (f x) ;

const :: a -> b -> a ;
const a _ = a ;

fix :: (a -> a) -> a ;
fix f = f (fix f) ;
