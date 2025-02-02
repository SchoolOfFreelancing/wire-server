-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2020 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.

module Galley.API.IdMapping
  ( -- * endpoints
    getIdMappingH,
    postIdMappingH,

    -- * other functions
    resolveOpaqueUserId,
    resolveOpaqueConvId,
    createUserIdMapping,
    createConvIdMapping,
  )
where

import Control.Monad.Catch (throwM)
import qualified Data.Id as Id
import Data.Id (Id (Id, toUUID), OpaqueConvId, OpaqueUserId, idToText)
import Data.IdMapping (IdMapping (IdMapping, _imQualifiedId), MappedOrLocalId (Local, Mapped), hashQualifiedId)
import Data.Qualified (Qualified, renderQualifiedId)
import Galley.API.Error (federationNotEnabled)
import Galley.API.Util (JSON, isFederationEnabled)
import Galley.App (Galley, fromJsonBody)
import qualified Galley.Data.IdMapping as Data (getIdMapping, insertIdMapping)
import qualified Galley.Intra.IdMapping as Intra
import Galley.Types.IdMapping (PostIdMappingRequest (PostIdMappingRequest), PostIdMappingResponse (PostIdMappingResponse), mkPostIdMappingRequest)
import Imports
import Network.HTTP.Types (forbidden403, notFound404)
import Network.Wai (Response)
import Network.Wai.Predicate ((:::) ((:::)))
import Network.Wai.Utilities (JsonRequest, empty, json, setStatus)
import qualified System.Logger.Class as Log

--------------------------------------------------------------------------------
-- endpoints

-- | For debugging and tests.
-- We just pick @()@ here, as conversation and user ID mappings share a table.
getIdMappingH :: Id (Id.Opaque ()) ::: JSON -> Galley Response
getIdMappingH (opaqueId ::: _) =
  ifFederationIsEnabled $
    getIdMapping opaqueId <&> \case
      Nothing -> empty & setStatus notFound404
      Just idMapping -> json idMapping

getIdMapping :: forall a. Id (Id.Opaque a) -> Galley (Maybe (IdMapping a))
getIdMapping opaqueId = do
  Data.getIdMapping assumedMappedId
  where
    assumedMappedId = Id (toUUID opaqueId) :: Id (Id.Mapped a)

-- | Used by Brig and Galley to notify each other when they find a new 'IdMapping'.
postIdMappingH ::
  JsonRequest PostIdMappingRequest ::: JSON ->
  Galley Response
postIdMappingH (req ::: _) =
  ifFederationIsEnabled $
    fmap json . postIdMapping =<< fromJsonBody req

-- | Blindly writes the mapping to our own database, unconditionally.
-- The mapping is deterministic, so we don't bother reading existing values.
-- If we overwrite an existing entry, then it will be overwritten with the same value as it
-- had before.
--
-- This function doesn't intra-call Brig, so we don't end up in an infinite loop of calling
-- each other.
postIdMapping :: PostIdMappingRequest -> Galley PostIdMappingResponse
postIdMapping (PostIdMappingRequest qualifiedId) = do
  let mappedId = Id (hashQualifiedId qualifiedId)
  Data.insertIdMapping (IdMapping mappedId qualifiedId)
  pure (PostIdMappingResponse mappedId)

ifFederationIsEnabled :: Galley Response -> Galley Response
ifFederationIsEnabled action =
  isFederationEnabled >>= \case
    -- This should only be called by Brig if federation is enabled there,
    -- so either there is some mis-configuration going on (Brig and Galley
    -- out of sync) or there is a bug.
    False -> pure (empty & setStatus forbidden403)
    True -> action

--------------------------------------------------------------------------------
-- helpers

-- FUTUREWORK(federation, #1178): implement function to resolve IDs in batch

resolveOpaqueUserId :: OpaqueUserId -> Galley (MappedOrLocalId Id.U)
resolveOpaqueUserId = resolveOpaqueId

resolveOpaqueConvId :: OpaqueConvId -> Galley (MappedOrLocalId Id.C)
resolveOpaqueConvId = resolveOpaqueId

-- | It doesn't really matter which type of 'IdMapping' we create, as they will all be
-- identical and can therefore be written to the same table.
--
-- We still don't want to expose this function directly and instead use specialized versions.
resolveOpaqueId :: forall a. Id (Id.Opaque a) -> Galley (MappedOrLocalId a)
resolveOpaqueId opaqueId = do
  isFederationEnabled >>= \case
    False ->
      -- don't check the ID mapping, just assume it's local
      pure $ Local assumedLocalId
    True ->
      Data.getIdMapping assumedMappedId <&> \case
        Just idMapping -> Mapped idMapping
        Nothing -> Local assumedLocalId
  where
    assumedMappedId = Id (toUUID opaqueId) :: Id (Id.Mapped a)
    assumedLocalId = Id (toUUID opaqueId) :: Id a

createUserIdMapping :: Qualified (Id (Id.Remote Id.U)) -> Galley (IdMapping Id.U)
createUserIdMapping = createIdMapping

createConvIdMapping :: Qualified (Id (Id.Remote Id.C)) -> Galley (IdMapping Id.C)
createConvIdMapping = createIdMapping

-- | It doesn't really matter which type of 'IdMapping' we create, as they will all be
-- identical and can therefore be written to the same table.
--
-- We still don't want to expose this function directly and instead use specialized versions.
createIdMapping :: Typeable a => Qualified (Id (Id.Remote a)) -> Galley (IdMapping a)
createIdMapping qualifiedId = do
  isFederationEnabled >>= \case
    False ->
      throwM . federationNotEnabled $ pure qualifiedId
    True -> do
      -- This should be optimized for the common case that the mapping already exists.
      -- We have to compute the hash already just to check if there is an
      -- existing mapping, since the mapped ID is the primary key.
      let mappedId = Id (hashQualifiedId qualifiedId)
      let idMapping = IdMapping mappedId qualifiedId
      Data.getIdMapping mappedId >>= \case
        Just existingMapping ->
          when (_imQualifiedId existingMapping /= qualifiedId)
            $ Log.err
            $ Log.msg @Text "Conflict when creating IdMapping"
              . Log.field "mapped_id" (idToText mappedId)
              . Log.field "existing_qualified_id" (renderQualifiedId qualifiedId)
              . Log.field "new_qualified_id" (renderQualifiedId (_imQualifiedId existingMapping))
        Nothing -> do
          Data.insertIdMapping idMapping
          Intra.createIdMappingInBrig (mkPostIdMappingRequest qualifiedId)
      pure idMapping
