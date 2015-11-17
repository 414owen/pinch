{-# LANGUAGE Rank2Types #-}
-- |
-- Module      :  Pinch.Internal.Pinchable.Parser
-- Copyright   :  (c) Abhinav Gupta 2015
-- License     :  BSD3
--
-- Maintainer  :  Abhinav Gupta <mail@abhinavg.net>
-- Stability   :  experimental
--
-- Implements a continuation based version of the @Either e@ monad.
--
module Pinch.Internal.Pinchable.Parser
    ( Parser
    , runParser
    , parserCatch
    ) where

import Control.Applicative
import Control.Monad

-- | Failure continuation. Called with the failure message.
type Failure   r = String  -> r
type Success a r = a       -> r
-- ^ Success continuation. Called with the result.

-- | A simple continuation-based parser.
--
-- This is just @Either e a@ in continuation-passing style.
newtype Parser a = Parser
    { unParser :: forall r.
          Failure r    -- Failure continuation
       -> Success a r  -- Success continuation
       -> r
    } -- TODO can probably track position in the struct

instance Functor Parser where
    fmap f (Parser g) = Parser $ \kFail kSucc -> g kFail (kSucc . f)

instance Applicative Parser where
    pure a = Parser $ \_ kSucc -> kSucc a

    Parser f' <*> Parser a' =
        Parser $ \kFail kSuccB ->
            f' kFail $ \f ->
            a' kFail $ \a ->
                kSuccB (f a)

instance Alternative Parser where
    empty = Parser $ \kFail _ -> kFail "Alternative.empty"

    Parser l' <|> Parser r' =
        Parser $ \kFail kSucc ->
            l' (\_ -> r' kFail kSucc) kSucc

instance Monad Parser where
    fail msg = Parser $ \kFail _ -> kFail msg
    return = pure
    (>>) = (*>)

    Parser a' >>= k =
        Parser $ \kFail kSuccB ->
            a' kFail $ \a ->
            unParser (k a) kFail kSuccB

instance MonadPlus Parser where
    mzero = empty
    mplus = (<|>)

-- | Run a @Parser@ and return the result inside an @Either@.
runParser :: Parser a -> Either String a
runParser p = unParser p Left Right

-- | Allows handling parse errors.
parserCatch
    :: Parser a -> (String -> Parser b) -> (a -> Parser b) -> Parser b
parserCatch (Parser a) = a
