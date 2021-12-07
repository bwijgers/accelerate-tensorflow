{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}
{-# OPTIONS_HADDOCK hide #-}
-- |
-- Module      : Data.Array.Accelerate.TensorFlow.CodeGen
-- Copyright   : [2021] The Accelerate Team
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <trevor.mcdonell@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.TensorFlow.CodeGen (

  buildAcc,
  buildAfun,

) where

import Data.Array.Accelerate.TensorFlow.CodeGen.AST
import Data.Array.Accelerate.TensorFlow.CodeGen.Base
import Data.Array.Accelerate.TensorFlow.CodeGen.Environment
import Data.Array.Accelerate.TensorFlow.CodeGen.Exp
import Data.Array.Accelerate.TensorFlow.CodeGen.Tensor

import Data.Array.Accelerate.AST
import Data.Array.Accelerate.AST.LeftHandSide
import Data.Array.Accelerate.AST.Var
import Data.Array.Accelerate.Array.Data
import Data.Array.Accelerate.Array.Unique
import Data.Array.Accelerate.Lifetime
import Data.Array.Accelerate.Representation.Array                   hiding ( shape )
import Data.Array.Accelerate.Representation.Shape
import Data.Array.Accelerate.Representation.Slice
import Data.Array.Accelerate.Representation.Type
import Data.Array.Accelerate.Type

import Data.ProtoLens.Default                                       ( def )
import Lens.Family2
import qualified Proto.Tensorflow.Core.Framework.Tensor             as TF
import qualified Proto.Tensorflow.Core.Framework.TensorShape_Fields as TensorShape
import qualified Proto.Tensorflow.Core.Framework.Tensor_Fields      as TF
import qualified TensorFlow.Build                                   as TF
import qualified TensorFlow.Core                                    as TF
import qualified TensorFlow.GenOps.Core                             as TF
import qualified TensorFlow.Ops                                     as TF hiding ( placeholder' )
import qualified TensorFlow.Types                                   as TF

import Control.Monad.State
import Data.ByteString.Internal                                     as B
import Foreign.ForeignPtr
import Foreign.Storable
import Text.Printf
import qualified Data.Text                                          as T


buildAcc :: Acc a -> Tensors a
buildAcc acc = buildOpenAcc Aempty acc

buildAfun :: [[Int]] -> Afun f -> Tfun f
buildAfun shapes f = evalState (buildOpenAfun shapes Aempty f) 0

buildOpenAfun :: [[Int]] -> Aval aenv -> OpenAfun aenv f -> State Int (OpenTfun aenv f)
buildOpenAfun (sh:shs) aenv (Alam lhs f) = do
  let
      go :: ALeftHandSide t aenv aenv' -> Aval aenv -> State Int (Aval aenv')
      go LeftHandSideWildcard{}                      env = return env
      go (LeftHandSidePair aR bR)                    env = go bR =<< go aR env
      go (LeftHandSideSingle arrR@(ArrayR _shR _eR)) env = state $ \i ->
        let sh'    = evalState (shape _shR) 0
            adata' = evalState (array _eR) 0

            shape :: ShapeR sh -> State Int (TensorShape sh)
            shape ShapeRz          = return ()
            shape (ShapeRsnoc shR) = do
              sz <- state $ \j -> (TF.placeholder' (TF.opName .~ TF.explicitName (T.pack (printf "input%d_shape%d" i j))), j+1)
              sh <- shape shR
              return (sh, sz)

            array :: TypeR t -> State Int (TensorArrayData t)
            array TupRunit         = return ()
            array (TupRpair aR bR) = (,) <$> array aR <*> array bR
            array (TupRsingle aR)  = scalar aR
              where
                scalar :: ScalarType t -> State Int (TensorArrayData t)
                scalar (SingleScalarType t) = single t
                scalar (VectorScalarType _) = unsupported "SIMD-vector types"

                single :: SingleType t -> State Int (TensorArrayData t)
                single (NumSingleType t) = num t

                num :: NumType t -> State Int (TensorArrayData t)
                num (IntegralNumType t) = integral t
                num (FloatingNumType t) = floating t

                integral :: IntegralType t -> State Int (TensorArrayData t)
                integral TypeInt8   = placeholder
                integral TypeInt16  = placeholder
                integral TypeInt32  = placeholder
                integral TypeInt64  = placeholder
                integral TypeWord8  = placeholder
                integral TypeWord16 = placeholder
                integral TypeWord32 = placeholder
                integral TypeWord64 = placeholder
                integral TypeInt    = placeholder
                integral TypeWord   = placeholder

                floating :: FloatingType t -> State Int (TensorArrayData t)
                floating TypeFloat  = placeholder
                floating TypeDouble = placeholder
                floating TypeHalf   = unsupported "half-precision floating point"

                placeholder :: TF.TensorType t => State Int (TF.Tensor TF.Build t)
                placeholder = state $ \j ->
                  let opName = TF.opName .~ TF.explicitName (T.pack (printf "input%d_adata%d" i j))
                      setShape = TF.opAttr "shape" .~ TF.Shape (fromIntegral <$> sh) -- TODO: Find correct shape from program
                  in  (TF.placeholder' (setShape . opName), j+1)
        in
        (env `Apush` Tensor arrR sh' adata', i+1)

  --
  aenv' <- go lhs aenv
  f'    <- buildOpenAfun shs aenv' f
  return $ Tlam lhs f'
--
buildOpenAfun [] aenv (Alam _ _) = error "Not enough shapes for arguments"
buildOpenAfun shapes aenv (Abody f) =
  let
      go :: ArraysR t -> Tensors t -> State Int (Tensors t)
      go TupRunit              ()                                     = return ()
      go (TupRpair aR bR)      (a, b)                                 = (,) <$> go aR a <*> go bR b
      go (TupRsingle ArrayR{}) (Tensor (ArrayR shR eR) _sh _adata) = state $ \i ->
        let
            sh'    = evalState (shape shR _sh) 0
            adata' = evalState (array eR _adata) 0

            shape :: ShapeR sh -> TensorShape sh -> State Int (TensorShape sh)
            shape ShapeRz         ()     = return ()
            shape (ShapeRsnoc tR) (t, h) = do
              h' <- state $ \j -> (TF.identity' (TF.opName .~ TF.explicitName (T.pack (printf "input%d_shape%d" i j))) h, j+1)
              t' <- shape tR t
              return (t', h')

            array :: TypeR t -> TensorArrayData t -> State Int (TensorArrayData t)
            array TupRunit         ()     = return ()
            array (TupRpair aR bR) (a, b) = (,) <$> array aR a <*> array bR b
            array (TupRsingle aR)  a      = scalar aR a

            scalar :: ScalarType t -> TensorArrayData t -> State Int (TensorArrayData t)
            scalar (SingleScalarType t) = single t
            scalar (VectorScalarType _) = unsupported "SIMD-vector types"

            single :: SingleType t -> TensorArrayData t -> State Int (TensorArrayData t)
            single (NumSingleType t) = num t

            num :: NumType t -> TensorArrayData t -> State Int (TensorArrayData t)
            num (IntegralNumType t) = integral t
            num (FloatingNumType t) = floating t

            integral :: IntegralType t -> TensorArrayData t -> State Int (TensorArrayData t)
            integral TypeInt8   = label
            integral TypeInt16  = label
            integral TypeInt32  = label
            integral TypeInt64  = label
            integral TypeWord8  = label
            integral TypeWord16 = label
            integral TypeWord32 = label
            integral TypeWord64 = label
            integral TypeInt    = label
            integral TypeWord   = label

            floating :: FloatingType t -> TensorArrayData t -> State Int (TensorArrayData t)
            floating TypeFloat  = label
            floating TypeDouble = label
            floating TypeHalf   = unsupported "half-precision floating point"

            label :: TF.TensorType t => TF.Tensor TF.Build t -> State Int (TF.Tensor TF.Build t)
            label t = state $ \j -> (TF.identity' (TF.opName .~ TF.explicitName (T.pack (printf "output%d_adata%d" i j))) t, j+1)
        in
        (Tensor (ArrayR shR eR) sh' adata', i+1)

      fR  = arraysR f
      f'  = evalState (go fR (buildOpenAcc aenv f)) 0
  in
  return $ Tbody fR f'


buildOpenAcc
    :: forall aenv arrs.
       Aval aenv
    -> OpenAcc aenv arrs
    -> Tensors arrs
buildOpenAcc aenv (OpenAcc pacc) =
  let
      buildA :: OpenAcc aenv (Array sh' e') -> Tensor sh' e'
      buildA = buildOpenAcc aenv

      aletL :: ALeftHandSide bnd aenv aenv'
            -> OpenAcc aenv  bnd
            -> OpenAcc aenv' body
            -> Tensors body
      aletL lhs bnd body = buildOpenAcc (aenv `apush` (lhs, buildOpenAcc aenv bnd)) body

      useL :: ArrayR (Array sh e)
           -> Array sh e
           -> Tensor sh e
      useL (ArrayR shR adataR) (Array sh adata) =
        let
            shape :: ShapeR sh -> sh -> TensorShape sh
            shape ShapeRz         ()     = ()
            shape (ShapeRsnoc tR) (t, h) = (shape tR t, TF.scalar (fromIntegral h))

            array :: TypeR t -> ArrayData t -> TensorArrayData t
            array TupRunit ()             = ()
            array (TupRpair aR bR) (a, b) = (array aR a, array bR b)
            array (TupRsingle aR) a       = scalar aR a
              where
                tensor :: forall s t. (Storable t, s ~ ScalarTensorDataR t, TF.TensorType s)
                       => UniqueArray t
                       -> TF.Tensor TF.Build s
                tensor ua =
                  let fp     = unsafeGetValue (uniqueArrayData ua)
                      values = B.fromForeignPtr (castForeignPtr fp) 0 (size shR sh * sizeOf (undefined :: t))

                      node :: TF.TensorProto
                      node = def
                           & TF.dtype .~ TF.tensorType (undefined :: s)
                           & TF.tensorShape.TensorShape.dim .~ [ def & TensorShape.size .~ fromIntegral x | x <- shapeToList shR sh ]
                           & TF.tensorContent .~ values
                  in
                  TF.const' (TF.opAttr "value" .~ node)

                scalar :: ScalarType t -> ArrayData t -> TensorArrayData t
                scalar (SingleScalarType t) = single t
                scalar (VectorScalarType _) = unsupported "SIMD-vector types"

                single :: SingleType t -> ArrayData t -> TensorArrayData t
                single (NumSingleType t) = num t

                num :: NumType t -> ArrayData t -> TensorArrayData t
                num (IntegralNumType t) = integral t
                num (FloatingNumType t) = floating t

                integral :: IntegralType t -> ArrayData t -> TensorArrayData t
                integral TypeInt8   = tensor
                integral TypeInt16  = tensor
                integral TypeInt32  = tensor
                integral TypeInt64  = tensor
                integral TypeWord8  = tensor
                integral TypeWord16 = tensor
                integral TypeWord32 = tensor
                integral TypeWord64 = tensor
                integral TypeInt    = tensor
                integral TypeWord   = tensor

                floating :: FloatingType t -> ArrayData t -> TensorArrayData t
                floating TypeFloat  = tensor
                floating TypeDouble = tensor
                floating TypeHalf   = unsupported "half-precision floating point"

            adata' = array adataR adata
            sh'    = shape shR sh
        in
        Tensor (ArrayR shR adataR) sh' adata'

      unitL :: TypeR e -> Exp aenv e -> Tensor () e
      unitL eR e =
        let sh' = ()
            e'  = buildOpenExp dim0 sh' Empty aenv e
        in
        Tensor (ArrayR dim0 eR) sh' e'

      mapL :: TypeR b -> Fun aenv (a -> b) -> OpenAcc aenv (Array sh a) -> Tensor sh b
      mapL bR (Lam lhs (Body e)) xs =
        let Tensor (ArrayR shR _) sh xs' = buildA xs
            bs                           = buildOpenExp shR sh (Empty `push` (lhs, xs')) aenv e
        in
        Tensor (ArrayR shR bR) sh bs
      mapL _ _ _ = error "impossible"

      -- XXX Assumes that the tensors have compatible shape!
      zipWithL :: TypeR c
               -> Fun aenv (a -> b -> c)
               -> OpenAcc aenv (Array sh a)
               -> OpenAcc aenv (Array sh b)
               -> Tensor sh c
      zipWithL cR (Lam lhsA (Lam lhsB (Body e))) xs ys =
        let Tensor (ArrayR shR _) sh xs' = buildA xs
            Tensor _              _  ys' = buildA ys
            cs                           = buildOpenExp shR sh (Empty `push` (lhsA, xs') `push` (lhsB, ys')) aenv e
        in
        Tensor (ArrayR shR cR) sh cs
      zipWithL _ _ _ _ = error "impossible"

      fillL :: ArrayR (Array sh e) -> Exp aenv sh -> Exp aenv e -> Tensor sh e
      fillL (ArrayR shR eR) sh e =
        let sh' = buildOpenExp shR (singleton shR) Empty aenv sh
            e'  = buildOpenExp shR sh'             Empty aenv e
        in
        Tensor (ArrayR shR eR) sh' e'

      generateL :: ArrayR (Array sh e) -> Exp aenv sh -> Fun aenv (sh -> e) -> Tensor sh e
      generateL = undefined

      replicateL
          :: SliceIndex slix sl co sh
          -> Exp aenv slix
          -> OpenAcc aenv (Array sl e)
          -> Tensor sh e
      replicateL slice slix acc =
        let
            Tensor (ArrayR _ eR) sl' e' = buildA acc
            slix'                       = buildOpenExp dim0 () Empty aenv slix
            shR                         = sliceDomainR slice
            sh'                         = extend slice slix' sl'

            sh_                         = shapeToTensor shR sh'
            sl_                         = shapeToTensor shR (pad slice sl')

            extend :: SliceIndex slix sl co sh -> TensorShape slix -> TensorShape sl -> TensorShape sh
            extend SliceNil              ()        ()       = ()
            extend (SliceAll sliceIdx)   (slx, ()) (sl, sz) = (extend sliceIdx slx sl, sz)
            extend (SliceFixed sliceIdx) (slx, sz) sl       = (extend sliceIdx slx sl, sz)

            pad :: SliceIndex slix sl co sh -> TensorShape sl -> TensorShape sh
            pad SliceNil              ()       = ()
            pad (SliceAll sliceIdx)   (sl, sz) = (pad sliceIdx sl, sz)
            pad (SliceFixed sliceIdx) sl       = (pad sliceIdx sl, TF.scalar 1)

            go :: TypeR s -> TensorArrayData s -> TensorArrayData s
            go TupRunit         ()     = ()
            go (TupRpair aR bR) (a, b) = (go aR a, go bR b)
            go (TupRsingle aR)  a      =
              let
                  scalar :: ScalarType s -> TensorArrayData s -> TensorArrayData s
                  scalar (SingleScalarType t) = single t
                  scalar (VectorScalarType _) = unsupported "vector types"

                  single :: SingleType s -> TensorArrayData s -> TensorArrayData s
                  single (NumSingleType t) = num t

                  num :: NumType s -> TensorArrayData s -> TensorArrayData s
                  num (IntegralNumType t) = integral t
                  num (FloatingNumType t) = floating t

                  integral :: IntegralType s -> TensorArrayData s -> TensorArrayData s
                  integral TypeInt8   s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeInt16  s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeInt32  s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeInt64  s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeWord8  s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeWord16 s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeWord32 s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeWord64 s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeInt    s = TF.tile (TF.reshape s sl_) sh_
                  integral TypeWord   s = TF.tile (TF.reshape s sl_) sh_

                  floating :: FloatingType s -> TensorArrayData s -> TensorArrayData s
                  floating TypeFloat  s = TF.tile (TF.reshape s sl_) sh_
                  floating TypeDouble s = TF.tile (TF.reshape s sl_) sh_
                  floating TypeHalf   _ = unsupported "half-precision floating point"
              in
              scalar aR a
        in
        Tensor (ArrayR shR eR) sh' (go eR e')
  in
  case pacc of
    Alet lhs bnd body                 -> aletL lhs bnd body
    Avar (Var _ ix)                   -> aprj ix aenv
    Apair xs ys                       -> (buildOpenAcc aenv xs, buildOpenAcc aenv ys)
    Anil                              -> ()
    -- Apply aR f xs                     -> undefined
    -- Aforeign aR asm f xs              -> undefined
    -- Acond p xs ys                     -> undefined
    -- Awhile p f xs                     -> undefined
    -- Atrace m xs ys                    -> undefined
    Use aR xs                         -> useL aR xs
    Unit eR e                         -> unitL eR e
    -- Reshape shR sh a                  -> undefined
    Generate aR sh f                  -> generateL aR sh f
    -- Transform aR sh p f xs            -> undefined
    Replicate slice slix sl           -> replicateL slice slix sl
    -- Slice sliceIndex sh slix          -> undefined
    Map bR f xs                       -> mapL bR f xs
    ZipWith cR f xs ys                -> zipWithL cR f xs ys
    -- Fold f z xs                       -> undefined
    -- FoldSeg iR f z xs ss              -> undefined
    -- Scan dir f z xs                   -> undefined
    -- Scan' dir f z xs                  -> undefined
    -- Permute f d p xs                  -> undefined
    -- Backpermute shR sh p xs           -> undefined
    -- Stencil sR tR f b xs              -> undefined
    -- Stencil2 sR1 sR2 tR f b1 xs b2 ys -> undefined

singleton :: ShapeR sh -> TensorShape sh
singleton ShapeRz          = ()
singleton (ShapeRsnoc shR) = (singleton shR, TF.scalar 1)

