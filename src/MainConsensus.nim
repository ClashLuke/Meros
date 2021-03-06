include MainDatabase

proc mainConsensus() {.forceCheck: [].} =
    {.gcsafe.}:
        try:
            consensus = newConsensus(
                functions,
                database,
                params.SEND_DIFFICULTY.toHash(384),
                params.DATA_DIFFICULTY.toHash(384)
            )
        except ValueError:
            doAssert(false, "Invalid initial Send/Data difficulty.")

        functions.consensus.getSendDifficulty = proc (): Hash[384] {.inline, forceCheck: [].} =
            consensus.filters.send.difficulty
        functions.consensus.getDataMinimumDifficulty = proc (): Hash[384] {.inline, forceCheck: [].} =
            minimumDataDifficulty
        functions.consensus.getDataDifficulty = proc (): Hash[384] {.inline, forceCheck: [].} =
            consensus.filters.data.difficulty

        #Provide access to if a holder is malicious.
        functions.consensus.isMalicious = proc (
            key: BLSPublicKey
        ): bool {.inline, forceCheck: [].} =
            consensus.malicious.hasKey(key)

        #Provide access to the holder's height.
        functions.consensus.getHeight = proc (
            key: BLSPublicKey
        ): int {.forceCheck: [].} =
            if consensus.malicious.hasKey(key):
                return consensus[key].archived + 2
            result = consensus[key].height

        #Provide access to consensus.
        functions.consensus.getElement = proc (
            key: BLSPublicKey,
            nonce: int
        ): Element {.forceCheck: [
            IndexError
        ].} =
            if consensus.malicious.hasKey(key):
                if nonce == consensus[key].archived + 1:
                    try:
                        return consensus.malicious[key][0]
                    except KeyError as e:
                        doAssert(false, "Couldn't get a MeritRemoval despite confirming it exists: " & e.msg)
                elif nonce <= consensus[key].archived:
                    discard
                elif nonce < consensus[key].height:
                    raise newException(IndexError, "Element requested has been reverted.")

            try:
                result = consensus[key][nonce]
            except IndexError as e:
                fcRaise e

        #Provide access to the MeritHolderRecords of holders with unarchived Elements.
        functions.consensus.getUnarchivedRecords = proc (): tuple[
            records: seq[MeritHolderRecord],
            aggregate: BLSSignature
        ] {.forceCheck: [].} =
            #Signatures.
            var signatures: seq[BLSSignature] = @[]

            #Iterate over every holder.
            for holder in consensus.holders():
                #Continue if this user doesn't have unarchived Elements.
                if consensus[holder].archived == consensus[holder].height - 1:
                    continue

                #Since there are unarchived consensus, add the MeritHolderRecord.
                var
                    nonce: int = consensus[holder].height - 1
                    merkle: Hash[384]
                try:
                    merkle = consensus[holder].calculateMerkle(nonce)
                except IndexError as e:
                    doAssert(false, "MeritHolder.calculateMerkle() threw an IndexError when the index was holder.height - 1: " & e.msg)

                result.records.add(newMeritHolderRecord(
                    holder,
                    nonce,
                    merkle
                ))

                #Add all the pending signatures to signatures.
                try:
                    for e in consensus[holder].archived + 1 ..< consensus[holder].height:
                        signatures.add(consensus[holder].signatures[e])
                except KeyError as e:
                    doAssert(false, "Couldn't get a signature of a pending Element we know we have: " & e.msg)
                except IndexError as e:
                    doAssert(false, "Couldn't get an Element we know we have: " & e.msg)

            #Aggregate the Signatures.
            try:
                result.aggregate = signatures.aggregate()
            except BLSError as e:
                doAssert(false, "Failed to aggregate the signatures: " & e.msg)

        functions.consensus.getStatus = proc (
            hash: Hash[384]
        ): TransactionStatus {.raises: [
            IndexError
        ].} =
            try:
                result = consensus.getStatus(hash)
            except IndexError:
                raise newException(IndexError, "Couldn't find a Status for that hash.")

        functions.consensus.getThreshold = proc (
            epoch: int
        ): int {.inline, raises: [].} =
            merit.state.nodeThresholdAt(epoch)

        #Handle Elements.
        functions.consensus.addVerification = proc (
            verif: Verification
        ) {.forceCheck: [
            ValueError
        ].} =
            #Print that we're adding the Verification.
            echo "Adding a new Verification from a Block."

            #See if the Transaction exists.
            var txExists: bool
            try:
                discard transactions[verif.hash]
                txExists = true
            except IndexError:
                txExists = false

            #Add the Verification to the Elements DAG.
            try:
                consensus.add(merit.state, verif, txExists)
            except ValueError as e:
                fcRaise e
            #Since we got this from a Block, we should've already synced all previous Elements.
            except GapError:
                doAssert(false, "Adding a Verification from a Block which we verified, despite not having all mentioned Elements.")
            except DataExists as e:
                doAssert(false, "Tried to add an unsigned Element we already have: " & e.msg)

            echo "Successfully added a new Verification."

        #Handle SignedElements.
        functions.consensus.addSignedVerification = proc (
            verif: SignedVerification
        ) {.forceCheck: [
            ValueError,
            GapError,
            DataExists
        ].} =
            #Print that we're adding the SignedVerification.
            echo "Adding a new Signed Verification."

            #Check if this is cause for a MaliciousMeritRemoval.
            try:
                consensus.checkMalicious(verif)
            except GapError as e:
                fcRaise e
            #Already added.
            except DataExists as e:
                fcRaise e
            #MeritHolder committed a malicious act against the network.
            except MaliciousMeritHolder as e:
                #Flag the MeritRemoval.
                consensus.flag(merit.state, cast[SignedMeritRemoval](e.removal))

                try:
                    #Broadcast the first MeritRemoval.
                    functions.network.broadcast(
                        MessageType.SignedMeritRemoval,
                        cast[SignedMeritRemoval](consensus.malicious[verif.holder][0]).signedSerialize()
                    )
                except KeyError as e:
                    doAssert(false, "Couldn't get the MeritRemoval of someone who just had one created: " & e.msg)
                return

            #See if the Transaction exists.
            try:
                discard transactions[verif.hash]
            except IndexError:
                raise newException(ValueError, "Unknown Verification.")

            #Add the SignedVerification to the Elements DAG.
            try:
                consensus.add(merit.state, verif)
            #Invalid signature.
            except ValueError as e:
                fcRaise e
            #Missing Elements before this Verification.
            except GapError as e:
                fcRaise e

            echo "Successfully added a new Signed Verification."

            #Broadcast the SignedVerification.
            functions.network.broadcast(
                MessageType.SignedVerification,
                verif.signedSerialize()
            )

        functions.consensus.addMeritRemoval = proc (
            mr: MeritRemoval
        ) {.forceCheck: [
            ValueError
        ].} =
            #Print that we're adding the MeritRemoval.
            echo "Adding a new Merit Removal from a Block."

            #Add the MeritRemoval.
            try:
                consensus.add(merit.state, mr)
            except ValueError as e:
                fcRaise e

            echo "Successfully added a new Merit Removal."

        functions.consensus.addSignedMeritRemoval = proc (
            mr: SignedMeritRemoval
        ) {.forceCheck: [
            ValueError
        ].} =
            #Print that we're adding the MeritRemoval.
            echo "Adding a new Merit Removal."

            #Add the MeritRemoval.
            try:
                consensus.add(merit.state, mr)
            except ValueError as e:
                fcRaise e

            echo "Successfully added a new Signed Merit Removal."

            #Broadcast the first MeritRemoval.
            try:
                functions.network.broadcast(
                    MessageType.SignedMeritRemoval,
                    cast[SignedMeritRemoval](consensus.malicious[mr.holder][0]).signedSerialize()
                )
            except KeyError as e:
                doAssert(false, "Couldn't get the MeritRemoval of someone who just had one created: " & e.msg)
