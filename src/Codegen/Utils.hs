{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
module Codegen.Utils where

import Misc
import Control.Monad.Except
import Control.Monad.State.Lazy
import Control.Applicative

import Data.Char (ord)

import qualified Types as Ty
import qualified Parser.Lib as L
import qualified Parser.Lang as P
import qualified LLVM.AST as AST
import qualified LLVM.AST.Constant as Cst
import qualified LLVM.AST.FunctionAttribute as FnAttr
import qualified LLVM.AST.Global as Glb
import qualified LLVM.AST.Linkage as Lnk
import qualified LLVM.AST.Type as T
import qualified LLVM.AST.Typed as Tpd
import qualified LLVM.AST.Float as Flt
import qualified LLVM.IRBuilder.Module as M
import qualified LLVM.IRBuilder.Monad as Mn
import qualified Data.Map as Map

data FnDecl = FnDecl {
    ty :: Ty.Scheme,
    body :: Maybe (P.Stmt (L.Range, Ty.Type)),
    impls :: Map.Map Ty.Type AST.Operand
} deriving (Show, Eq)
data Env = Env {
    vars :: [Map.Map Ty.Name (Ty.Type, AST.Operand)],
    decls :: Map.Map Ty.Name FnDecl,
    exprs :: [(Ty.Type, AST.Operand)],
    anon_count :: Int,
    lambda_count :: Int
} deriving (Show, Eq)
newtype CodegenTopLevel a = CodegenTopLevel {
    runCodegenTopLevel :: M.ModuleBuilderT (State Env) a
} deriving (Functor, Applicative, Monad, MonadFix, MonadState Env, M.MonadModuleBuilder)
newtype Codegen a = Codegen {
    runCodegen :: Mn.IRBuilderT CodegenTopLevel a
}  deriving (Functor, Applicative, Monad, MonadFix, MonadState Env, Mn.MonadIRBuilder)

freshAnonName :: MonadState Env m => m String
freshAnonName = do
    count <- gets anon_count
    modify $ \env -> env { anon_count = count + 1 }
    return ("_anon_" <> show count)

freshLambdaName :: MonadState Env m => m String
freshLambdaName = do
    count <- gets lambda_count
    modify $ \env -> env { lambda_count = count + 1 }
    return ("_lambda_" <> show count)

newScope, dropScope :: MonadState Env m => m ()
newScope = modify $ \env -> env { vars = Map.empty : vars env }
dropScope = modify $ \env -> env { vars = tail $ vars env }
withScope :: MonadState Env m => m a -> m a
withScope action = do
    newScope
    ret <- action
    dropScope
    return ret

pushDecl :: MonadState Env m => Ty.Name -> Ty.Scheme -> Maybe (P.Stmt (L.Range, Ty.Type)) -> m ()
pushDecl name ty body = modify $ \env -> env { decls = Map.insert name FnDecl{ ty, body, impls = Map.empty } $ decls env }
pushImpl :: MonadState Env m => Ty.Name -> Ty.Type -> AST.Operand -> m ()
pushImpl name ty op = modify $ \env -> env { decls = Map.adjust (\el -> el { impls = Map.insert ty op $ impls el }) name $ decls env }
pushDeclAndImpl :: MonadState Env m => Ty.Name -> Ty.Scheme -> (Ty.Type, AST.Operand) -> m ()
pushDeclAndImpl name ty (impl_ty, op) = modify $ \env -> env { decls = Map.insert name FnDecl{ ty, body = Nothing, impls = Map.singleton impl_ty op } $ decls env }
pushVar :: MonadState Env m => Ty.Name -> Ty.Type -> AST.Operand -> m ()
pushVar name ty operand = modify $ \env ->
    if null $ vars env
        then env { vars = [Map.singleton name (ty, operand)] }
        else env { vars = Map.insert name (ty, operand) (head $ vars env) : tail (vars env) }
pushExpr :: MonadState Env m => (Ty.Type, AST.Operand) -> m ()
pushExpr expr = modify $ \env -> env { exprs = expr : exprs env }

getVar :: MonadState Env m => Ty.Name -> m (Maybe (Ty.Type, AST.Operand))
getVar name = gets $ \env -> env |> vars |> map (Map.lookup name) |> foldl (<|>) Nothing
getDecl :: MonadState Env m => Ty.Name -> m (Maybe FnDecl)
getDecl name = gets $ \env -> env |> decls |> Map.lookup name
getImpl :: MonadState Env m => Ty.Name -> Ty.Type -> m (Maybe AST.Operand)
getImpl name ty = do
    maybe_defn <- gets $ \env -> env |> decls |> Map.lookup name
    return $ do
        defn <- maybe_defn
        Map.lookup ty $ impls defn

int, double, bool, void :: T.Type
int = T.i64
double = T.double
bool = T.i1
void = T.void

defaultValue :: Ty.Type -> Cst.Constant
defaultValue (Ty.TCon (Ty.TC "integer")) = Cst.Int 64 0
defaultValue (Ty.TCon (Ty.TC "double")) = Cst.Float (Flt.Double 0)
defaultValue (Ty.TCon (Ty.TC "bool")) = Cst.Int 1 0
defaultValue ty@(_ Ty.:-> _) = Cst.Null (irType ty)
defaultValue ty = error ("no default value defined for " <> show ty)

irType :: Ty.Type -> T.Type
irType (Ty.TCon (Ty.TC "integer")) = int
irType (Ty.TCon (Ty.TC "double")) = double
irType (Ty.TCon (Ty.TC "bool")) = bool
irType (Ty.TCon (Ty.TC "void")) = Codegen.Utils.void
irType (args Ty.:-> ret_ty) = T.ptr $ T.FunctionType (irType ret_ty) (args |> map irType) False
irType ty = error $ show ty

-- | A constant static string pointer
stringPtr :: M.MonadModuleBuilder m => String -> AST.Name -> m AST.Operand
stringPtr str nm = do
    let asciiVals = map (fromIntegral . ord) str
        llvmVals  = map (Cst.Int 8) (asciiVals <> [0])
        char      = T.IntegerType 8
        charStar  = T.ptr char
        charArray = Cst.Array char llvmVals
        ty        = Tpd.typeOf charArray
    M.emitDefn $ AST.GlobalDefinition Glb.globalVariableDefaults {
          Glb.name        = nm
        , Glb.type'       = ty
        , Glb.linkage     = Lnk.External
        , Glb.isConstant  = True
        , Glb.initializer = Just charArray
        , Glb.unnamedAddr = Just AST.GlobalAddr
    }
    pure $ AST.ConstantOperand $ Cst.BitCast (Cst.GlobalReference (T.ptr ty) nm) charStar

-- | A constant static string pointer with internal linkage
preludeStringPtr :: M.MonadModuleBuilder m => String -> AST.Name -> m AST.Operand
preludeStringPtr str nm = do
    let asciiVals = map (fromIntegral . ord) str
        llvmVals  = map (Cst.Int 8) (asciiVals <> [0])
        char      = T.IntegerType 8
        charStar  = T.ptr char
        charArray = Cst.Array char llvmVals
        ty        = Tpd.typeOf charArray
    M.emitDefn $ AST.GlobalDefinition Glb.globalVariableDefaults {
          Glb.name        = nm
        , Glb.type'       = ty
        , Glb.linkage     = Lnk.Internal
        , Glb.isConstant  = True
        , Glb.initializer = Just charArray
        , Glb.unnamedAddr = Just AST.GlobalAddr
    }
    pure $ AST.ConstantOperand $ Cst.BitCast (Cst.GlobalReference (T.ptr ty) nm) charStar

-- | A function definition with external linkage
function :: M.MonadModuleBuilder m
    => AST.Name -> [(AST.Name, T.Type)] -> T.Type -> [AST.BasicBlock] -> m AST.Operand
function name argtys retty body = do
    M.emitDefn $ AST.GlobalDefinition $ Glb.functionDefaults {
        Glb.name = name,
        Glb.parameters = ([AST.Parameter ty name [] | (name, ty) <- argtys], False),
        Glb.returnType = retty,
        Glb.basicBlocks = body
    }
    let funty = T.ptr $ AST.FunctionType retty (map snd argtys) False
    pure $ AST.ConstantOperand $ Cst.GlobalReference funty name

-- | A function definition with internal linkage and alwaysinline attribute
preludeFunction :: M.MonadModuleBuilder m
  => AST.Name
  -> [(T.Type, M.ParameterName)]
  -> AST.Type
  -> ([AST.Operand] -> Mn.IRBuilderT m ())
  -> m AST.Operand
preludeFunction name argtys retty body = do
    let tys = fst <$> argtys
    (paramNames, blocks) <- Mn.runIRBuilderT Mn.emptyIRBuilder $ do
        paramNames <- forM argtys $ \(_, paramName) -> case paramName of
            M.NoParameterName -> Mn.fresh
            M.ParameterName p -> Mn.fresh `Mn.named` p
        body $ zipWith AST.LocalReference tys paramNames
        return paramNames
    let def = AST.GlobalDefinition Glb.functionDefaults {
        Glb.name = name,
        Glb.linkage = Lnk.Internal,
        Glb.functionAttributes = [Right FnAttr.AlwaysInline],
        Glb.parameters = (zipWith (\ty nm -> AST.Parameter ty nm []) tys paramNames, False),
        Glb.returnType = retty,
        Glb.basicBlocks = blocks
    }
    let funty = T.ptr $ AST.FunctionType retty (fst <$> argtys) False
    M.emitDefn def
    pure $ AST.ConstantOperand $ Cst.GlobalReference funty name

-- | An external function definition
extern :: M.MonadModuleBuilder m
    => AST.Name -> [(AST.Name, T.Type)] -> T.Type -> m AST.Operand
extern nm argtys retty = do
    M.emitDefn $ AST.GlobalDefinition Glb.functionDefaults {
        Glb.name        = nm,
        Glb.linkage     = Lnk.External,
        Glb.parameters  = ([AST.Parameter ty name [] | (name, ty) <- argtys], False),
        Glb.returnType  = retty
    }
    let funty = T.ptr $ AST.FunctionType retty (map snd argtys) False
    pure $ AST.ConstantOperand $ Cst.GlobalReference funty nm

-- | An external variadic argument function definition
externVarArgs :: M.MonadModuleBuilder m
    => AST.Name -> [(AST.Name, T.Type)] -> T.Type -> m AST.Operand
externVarArgs nm argtys retty = do
    M.emitDefn $ AST.GlobalDefinition Glb.functionDefaults {
        Glb.name        = nm,
        Glb.linkage     = Lnk.External,
        Glb.parameters  = ([AST.Parameter ty name [] | (name, ty) <- argtys], True),
        Glb.returnType  = retty
    }
    let funty = T.ptr $ AST.FunctionType retty (map snd argtys) True
    pure $ AST.ConstantOperand $ Cst.GlobalReference funty nm

-- | A global variable with external linkage
global :: M.MonadModuleBuilder m
    => AST.Name -> T.Type -> Cst.Constant -> m AST.Operand
global nm ty initVal = do
    M.emitDefn $ AST.GlobalDefinition Glb.globalVariableDefaults {
        Glb.name                  = nm,
        Glb.type'                 = ty,
        Glb.linkage               = Lnk.External,
        Glb.initializer           = Just initVal
    }
    pure $ AST.ConstantOperand $ Cst.GlobalReference (T.ptr ty) nm

-- | A global variable with internal linkage
preludeGlobal :: M.MonadModuleBuilder m
    => AST.Name -> T.Type -> Cst.Constant -> m AST.Operand
preludeGlobal nm ty initVal = do
    M.emitDefn $ AST.GlobalDefinition Glb.globalVariableDefaults {
        Glb.name                  = nm,
        Glb.type'                 = ty,
        Glb.linkage               = Lnk.Internal,
        Glb.initializer           = Just initVal
    }
    pure $ AST.ConstantOperand $ Cst.GlobalReference (T.ptr ty) nm

mangleType :: Ty.Type -> String
mangleType (Ty.TCon (Ty.TC ty)) = [head ty]
mangleType (t1s Ty.:-> t2) = "f" <> concatMap mangleType t1s <> "r" <> mangleType t2 <> "e"

mangleFunction :: String -> [Ty.Type] -> Ty.Type -> String
mangleFunction name args ret_ty =
    name <> "_" <> concatMap mangleType args <> "_" <> mangleType ret_ty
