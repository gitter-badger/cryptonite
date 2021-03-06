-- |
-- Module      : Crypto.PubKey.RSA.PKCS15
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : Good
--
module Crypto.PubKey.RSA.PKCS15
    (
    -- * padding and unpadding
      pad
    , padSignature
    , unpad
    -- * private key operations
    , decrypt
    , decryptSafer
    , sign
    , signSafer
    -- * public key operations
    , encrypt
    , verify
    ) where

import           Crypto.Random.Types
import           Crypto.PubKey.Internal (and')
import           Crypto.PubKey.RSA.Types
import           Crypto.PubKey.RSA.Prim
import           Crypto.PubKey.RSA (generateBlinder)
import           Crypto.PubKey.HashDescr
import           Crypto.Hash (HashAlgorithm)

import           Data.ByteString (ByteString)

import           Crypto.Internal.ByteArray (ByteArray, Bytes)
import qualified Crypto.Internal.ByteArray as B

-- | This produce a standard PKCS1.5 padding for encryption
pad :: (MonadRandom m, ByteArray message) => Int -> message -> m (Either Error message)
pad len m
    | B.length m > len - 11 = return (Left MessageTooLong)
    | otherwise             = do
        padding <- getNonNullRandom (len - B.length m - 3)
        return $ Right $ B.concat [ B.pack [0,2], padding, B.pack [0], m ]

  where
    -- get random non-null bytes
    getNonNullRandom :: (ByteArray bytearray, MonadRandom m) => Int -> m bytearray
    getNonNullRandom n = do
        bs0 <- getRandomBytes n
        let bytes = B.pack $ filter (/= 0) $ B.unpack (bs0 :: Bytes)
            left  = n - B.length bytes
        if left == 0
            then return bytes
            else do bend <- getNonNullRandom left
                    return (bytes `B.append` bend)

-- | Produce a standard PKCS1.5 padding for signature
padSignature :: ByteArray signature => Int -> signature -> Either Error signature
padSignature klen signature
    | klen < siglen+1 = Left SignatureTooLong
    | otherwise       = Right (B.pack padding `B.append` signature)
  where
        siglen    = B.length signature
        padding   = 0 : 1 : (replicate (klen - siglen - 3) 0xff ++ [0])

-- | Try to remove a standard PKCS1.5 encryption padding.
unpad :: ByteArray bytearray => bytearray -> Either Error bytearray
unpad packed
    | paddingSuccess = Right m
    | otherwise      = Left MessageNotRecognized
  where
        (zt, ps0m)   = B.splitAt 2 packed
        (ps, zm)     = B.span (/= 0) ps0m
        (z, m)       = B.splitAt 1 zm
        paddingSuccess = and' [ zt `B.constEq` (B.pack [0,2] :: Bytes)
                              , z == B.zero 1
                              , B.length ps >= 8
                              ]

-- | decrypt message using the private key.
--
-- When the decryption is not in a context where an attacker could gain
-- information from the timing of the operation, the blinder can be set to None.
--
-- If unsure always set a blinder or use decryptSafer
decrypt :: Maybe Blinder -- ^ optional blinder
        -> PrivateKey    -- ^ RSA private key
        -> ByteString    -- ^ cipher text
        -> Either Error ByteString
decrypt blinder pk c
    | B.length c /= (private_size pk) = Left MessageSizeIncorrect
    | otherwise                       = unpad $ dp blinder pk c

-- | decrypt message using the private key and by automatically generating a blinder.
decryptSafer :: MonadRandom m
             => PrivateKey -- ^ RSA private key
             -> ByteString -- ^ cipher text
             -> m (Either Error ByteString)
decryptSafer pk b = do
    blinder <- generateBlinder (private_n pk)
    return (decrypt (Just blinder) pk b)

-- | encrypt a bytestring using the public key.
--
-- the message needs to be smaller than the key size - 11
encrypt :: MonadRandom m => PublicKey -> ByteString -> m (Either Error ByteString)
encrypt pk m = do
    r <- pad (public_size pk) m
    case r of
        Left err -> return $ Left err
        Right em -> return $ Right (ep pk em)

-- | sign message using private key, a hash and its ASN1 description
--
-- When the signature is not in a context where an attacker could gain
-- information from the timing of the operation, the blinder can be set to None.
--
-- If unsure always set a blinder or use signSafer
sign :: HashAlgorithm hashAlg
     => Maybe Blinder -- ^ optional blinder
     -> HashDescr hashAlg ByteString -- ^ hash descriptor
     -> PrivateKey    -- ^ private key
     -> ByteString    -- ^ message to sign
     -> Either Error ByteString
sign blinder hashDescr pk m = dp blinder pk `fmap` makeSignature hashDescr (private_size pk) m

-- | sign message using the private key and by automatically generating a blinder.
signSafer :: (HashAlgorithm hashAlg, MonadRandom m)
          => HashDescr hashAlg ByteString -- ^ Hash descriptor
          -> PrivateKey -- ^ private key
          -> ByteString -- ^ message to sign
          -> m (Either Error ByteString)
signSafer hashDescr pk m = do
    blinder <- generateBlinder (private_n pk)
    return (sign (Just blinder) hashDescr pk m)

-- | verify message with the signed message
verify :: HashAlgorithm hashAlg
       => HashDescr hashAlg ByteString
       -> PublicKey
       -> ByteString
       -> ByteString
       -> Bool
verify hashDescr pk m sm =
    case makeSignature hashDescr (public_size pk) m of
        Left _  -> False
        Right s -> s == (ep pk sm)

-- | make signature digest, used in 'sign' and 'verify'
makeSignature :: HashAlgorithm hashAlg
              => HashDescr hashAlg ByteString
              -> Int
              -> ByteString
              -> Either Error ByteString
makeSignature hashDescr klen m = padSignature klen (runHashDescr hashDescr m)
