{-# LANGUAGE DeriveFunctor #-}
module Annotation where

data Ann a b =
    Ann a b
    deriving (Show, Eq, Functor)

annotation :: Ann a b -> a
annotation (Ann a _) = a
