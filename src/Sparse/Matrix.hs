{-# LANGUAGE CPP #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-----------------------------------------------------------------------------
-- |
-- Copyright   :  (C) 2013 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
-- Sparse Matrices in Morton order
--
----------------------------------------------------------------------------

module Sparse.Matrix
  (
  -- * Sparse Matrices
    Mat(..)
  -- * Keys
  , Key
  , key, shuffled, unshuffled
  -- * Construction
  , fromList
  , singleton
  , ident
  , empty
  -- * Consumption
  , count
  -- * Distinguishable Zero
  , Eq0(..)
  -- * Customization
  , addWith
  , multiplyWith
  , nonZero
  -- * Lenses
  , _Mat, keys, values
  ) where

import Control.Applicative hiding (empty)
import Control.Lens
import Data.Bits
import Data.Foldable
import Data.Function (on)
import qualified Data.Vector.Algorithms.Intro as Intro
import qualified Data.Vector.Generic as G
import qualified Data.Vector.Hybrid as H
import qualified Data.Vector.Hybrid.Internal as H
import qualified Data.Vector.Unboxed as U
import Data.Word
import Sparse.Matrix.Fusion
import Sparse.Matrix.Key

-- * Distinguishable Zero

class Eq0 a where
  isZero :: a -> Bool
#ifndef HLINT
  default isZero :: (Num a, Eq a) => a -> Bool
  isZero = (0 ==)
  {-# INLINE isZero #-}
#endif

instance Eq0 Int
instance Eq0 Word
instance Eq0 Integer
instance Eq0 Float
instance Eq0 Double

-- * Sparse Matrices

newtype Mat v a = Mat { runMat :: H.Vector U.Vector v (Key, a) }

instance (G.Vector v a, Show a) => Show (Mat v a) where
  showsPrec d (Mat v) = showsPrec d v

instance (G.Vector v a, Read a) => Read (Mat v a) where
  readsPrec d r = [ (Mat m, t) | (m, t) <- readsPrec d r ]

-- | This isomorphism lets you access the internal structure of a matrix
_Mat :: Iso (Mat u a) (Mat v b) (H.Vector U.Vector u (Key, a)) (H.Vector U.Vector v (Key, b))
_Mat = iso runMat Mat
{-# INLINE _Mat #-}

-- | Access the keys of a matrix
keys :: Lens' (Mat v a) (U.Vector Key)
keys f = _Mat $ \ (H.V ks vs) -> f ks <&> \ks' -> H.V ks' vs
{-# INLINE keys #-}

-- | Access the keys of a matrix
values :: Lens (Mat u a) (Mat v b) (u a) (v b)
values f = _Mat $ \ (H.V ks vs) -> f vs <&> \vs' -> H.V ks vs'
{-# INLINE values #-}

instance Functor v => Functor (Mat v) where
  fmap = over (values.mapped)
  {-# INLINE fmap #-}

instance Foldable v => Foldable (Mat v) where
  foldMap = foldMapOf (values.folded)
  {-# INLINE foldMap #-}

instance Traversable v => Traversable (Mat v) where
  traverse = values.traverse
  {-# INLINE traverse #-}

type instance IxValue (Mat v a) = a
type instance Index (Mat v a) = Key

instance (Applicative f, G.Vector v a, G.Vector v b) => Each f (Mat v a) (Mat v b) a b where
  each f (Mat v@(H.V ks _)) = Mat . H.V ks . G.fromListN (G.length v) <$> traverse f' (G.toList v) where
    f' = uncurry (indexed f)
  {-# INLINE each #-}

instance (Functor f, Contravariant f, G.Vector v a) => Contains f (Mat v a) where
  contains = containsIx

instance (Applicative f, G.Vector v a) => Ixed f (Mat v a) where
  ix i f m@(Mat (H.V ks vs))
    | Just j <- ks U.!? l, i == j = indexed f i (vs G.! l) <&> \v -> Mat (H.V ks (vs G.// [(l,v)]))
    | otherwise                   = pure m
    where l = search (\j -> (ks U.! j) >= i) 0 (U.length ks)
  {-# INLINE ix #-}

{-
instance G.Vector v a => At (Mat v a) where
  at i f m@(Mat (H.V ks vs)) = case ks U.!? l of
    Just j
      | i == j -> indexed f i (Just (vs G.! l)) <&> \mv -> case mv of
        Just v  -> Mat $ H.V ks (vs G.// [(l,v)])
        Nothing  -> undefined -- TODO: delete
    _ -> indexed f i Nothing <&> \mv -> case mv of
        Just _v -> undefined -- TODO: insert v
        Nothing -> m
    where l = search (\j -> (ks U.! j) >= i) 0 (U.length ks)
  {-# INLINE at #-}
-}

instance Eq0 (Mat v a) where
  isZero = H.null . runMat
  {-# INLINE isZero #-}

-- * Construction

-- | Build a sparse matrix.
fromList :: G.Vector v a => [(Key, a)] -> Mat v a
fromList xs = Mat $ H.modify (Intro.sortBy (compare `on` fst)) $ H.fromList xs
{-# INLINE fromList #-}

-- | @singleton@ makes a matrix with a singleton value at a given location
singleton :: G.Vector v a => Key -> a -> Mat v a
singleton k v = Mat $ H.singleton (k,v)
{-# INLINE singleton #-}

-- | @ident n@ makes an @n@ x @n@ identity matrix
ident :: (G.Vector v a, Num a) => Word32 -> Mat v a
ident w = Mat $ H.generate (fromIntegral w) $ \i -> let i' = fromIntegral i in (key i' i', 1)
{-# INLINE ident #-}

-- | The empty matrix
empty :: G.Vector v a => Mat v a
empty = Mat H.empty
{-# INLINE empty #-}

-- * Consumption

-- | Count the number of non-zero entries in the matrix
count :: Mat v a -> Int
count = H.length . runMat
{-# INLINE count #-}

instance (G.Vector v a, Num a, Eq0 a) => Num (Mat v a) where
  abs    = over each abs
  {-# INLINE abs #-}
  signum = over each signum
  {-# INLINE signum #-}
  negate = over each negate
  {-# INLINE negate #-}
  fromInteger 0 = Mat H.empty
  fromInteger _ = error "Mat: fromInteger n"
  {-# INLINE fromInteger #-}
  (+) = addWith $ nonZero (+)
  {-# INLINE (+) #-}
  (-) = addWith $ nonZero (-)
  {-# INLINE (-) #-}
  (*) = multiplyWith (*) $ \ a b -> case a + b of
      c | isZero c  -> Nothing
        | otherwise -> Just c
  {-# INLINE (*) #-}

-- | Remove results that are equal to zero from a simpler function.
--
-- When used with @addWith@ or @multiplyWith@'s additive argumnt
-- this can help retain the sparsity of the matrix.
nonZero :: Eq0 c => (a -> b -> c) -> a -> b -> Maybe c
nonZero f a b = case f a b of
  c | isZero c -> Nothing
    | otherwise -> Just c
{-# INLINE nonZero #-}

-- | Merge two matrices where the indices coincide into a new matrix. This provides for generalized
-- addition. Return 'Nothing' for zero.
--
addWith :: G.Vector v a => (a -> a -> Maybe a) -> Mat v a -> Mat v a -> Mat v a
addWith f xs ys = Mat (G.unstream (mergeStreamsWith f (G.stream (runMat xs)) (G.stream (runMat ys))))
{-# INLINE addWith #-}

-- | Multiply two matrices using the specified multiplication and addition operation.
--
-- We can work with the Boolean semiring as a @Mat Data.Vector.Unboxed.Vector ()@ using:
--
-- @
-- booleanOr = addWith (const . Just)
-- booleanAnd = multiplyWith const (const . Just)
-- @
multiplyWith :: G.Vector v a => (a -> a -> a) -> (a -> a -> Maybe a) -> Mat v a -> Mat v a -> Mat v a
multiplyWith times plus x0 y0 = case compare (count x0) 1 of
  LT -> Mat H.empty
  EQ -> go1n x0 y0
  GT -> goR (critical x0) x0 y0
  where
    goL x cy y = case compare (count x) 1 of -- we need to check th count of the left hand matrix
      LT -> Mat H.empty
      EQ -> go1n x y
      GT -> go (critical x) x cy y
    {-# INLINE goL #-}
    goR cx x y = case compare (count y) 1 of -- we need to check the count of the right hand matrix
      LT -> Mat H.empty
      EQ -> gon1 x y
      GT -> go cx x (critical y) y
    {-# INLINE goR #-}
    go cx x cy y -- choose and execute a split
       | cx >= cy = case split cx x of
         (m0,m1) | parity cx -> goL m0 cy y `add` goL m1 cy y -- merge left and right traced out regions
                 | otherwise -> goL m0 cy y `fby` goL m1 cy y -- top and bottom
       | otherwise = case split cy y of
         (m0,m1) | parity cy -> goR cx x m0 `fby` goR cx x m1 -- left and right
                 | otherwise -> goR cx x m0 `add` goR cx x m1 -- merge top and bottom traced out regions
    gon1 (Mat x) (Mat y) = Mat (G.unstream (timesSingleton times (G.stream x) (H.head y)))
    {-# INLINE gon1 #-}
    go1n (Mat x) (Mat y) = Mat (G.unstream (singletonTimes times (H.head x) (G.stream y)))
    {-# INLINE go1n #-}
    add x y = addWith plus x y
    {-# INLINE add #-}
    fby (Mat l) (Mat r) = Mat (l H.++ r)
    {-# INLINE fby #-}
{-# INLINE multiplyWith #-}

-- * Utilities

-- | assuming @l <= h@. Returns @h@ if the predicate is never @True@ over @[l..h)@
search :: (Int -> Bool) -> Int -> Int -> Int
search p = go where
  go l h
    | l == h    = l
    | p m       = go l m
    | otherwise = go (m+1) h
    where m = l + div (h-l) 2
{-# INLINE search #-}

-- | @smear x@ finds the smallest @2^n-1 >= x@
smear :: Word64 -> Word64
smear k0 = k6 where
  k1 = k0 .|. unsafeShiftR k0 1
  k2 = k1 .|. unsafeShiftR k1 2
  k3 = k2 .|. unsafeShiftR k2 4
  k4 = k3 .|. unsafeShiftR k3 8
  k5 = k4 .|. unsafeShiftR k4 16
  k6 = k5 .|. unsafeShiftR k5 32
{-# INLINE smear #-}

-- | Determine the parity of
parity :: Word64 -> Bool
parity k0 = testBit k6 0 where
  k1 = k0 `xor` unsafeShiftR k0 1
  k2 = k1 `xor` unsafeShiftR k1 2
  k3 = k2 `xor` unsafeShiftR k2 4
  k4 = k3 `xor` unsafeShiftR k3 8
  k5 = k4 `xor` unsafeShiftR k4 16
  k6 = k5 `xor` unsafeShiftR k5 32
{-# INLINE parity #-}

-- | @critical m@ assumes @count m >= 2@ and tells you the mask to use for @split@
critical :: G.Vector v a => Mat v a -> Word64
critical (Mat (H.V ks _)) = smear (xor lo hi)  where -- `xor` unsafeShiftR bits 1 where -- the bit we're splitting on
  lo = runKey (U.head ks)
  hi = runKey (U.last ks)
{-# INLINE critical #-}

-- | partition along the critical bit into a 2-fat component and the remainder.
--
-- Note: the keys have 'junk' on the top of the keys, but it should be exactly the junk we need them to have when we rejoin the quadrants
--       or reassemble a key from matrix multiplication!
split :: G.Vector v a => Word64 -> Mat v a -> (Mat v a, Mat v a)
split mask (Mat h@(H.V ks _)) = (Mat m0, Mat m1)
  where
    !n = U.length ks
    !crit = mask `xor` unsafeShiftR mask 1
    !k = search (\i -> runKey (ks U.! i) .&. crit /= 0) 0 n
    (m0,m1) = H.splitAt k h
{-# INLINE split #-}

{-
-- Given a sorted array in [l,u), inserts val into its proper position,
-- yielding a sorted [l,u]
insert :: (PrimMonad m, GM.MVector v e) => (e -> e -> Ordering) -> v (PrimState m) e -> Int -> e -> Int -> m ()
insert cmp a l = loop
 where
 loop val j
   | j <= l    = GM.unsafeWrite a l val
   | otherwise = do e <- GM.unsafeRead a (j - 1)
                    case cmp val e of
                      LT -> GM.unsafeWrite a j e >> loop val (j - 1)
                      _  -> GM.unsafeWrite a j val
{-# INLINE insert #-}
-}

