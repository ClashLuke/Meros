#Errors.
import ../../lib/Errors

#Hash lib.
import ../../lib/Hash

#MinerWallet lib.
import ../../Wallet/MinerWallet

#GlobalFunctionBox object.
import ../../objects/GlobalFunctionBoxObj

#Consensus DB lib.
import ../Filesystem/DB/ConsensusDB

#Merkle lib.
import ../common/Merkle

#ConsensusIndex and MeritHolderRecord objects.
import ../common/objects/ConsensusIndexObj
import ../common/objects/MeritHolderRecordObj
export ConsensusIndex

#Transaction lib and Transactions object.
import ../Transactions/Transaction
import ../Transactions/objects/TransactionsObj

#Epoch object and State lib.
import ../Merit/objects/EpochsObj
import ../Merit/State

#SpamFilter object.
import objects/SpamFilterObj
export SpamFilterObj

#Signed Element object.
import objects/SignedElementObj
export SignedElementObj

#Element and MeritHolder libs.
import Element
import MeritHolder
export Element
export MeritHolder

#Consensus object.
import objects/ConsensusObj
export ConsensusObj

#Serialize Verification lib.
import ../../Network/Serialize/Consensus/SerializeVerification

#Seq utils standard lib.
import sequtils

#Tables standard lib.
import tables

#Constructor wrapper.
proc newConsensus*(
    functions: GlobalFunctionBox,
    db: DB,
    sendDiff: Hash[384],
    dataDiff: Hash[384]
): Consensus {.forceCheck: [].} =
    newConsensusObj(functions, db, sendDiff, dataDiff)

#Flag a MeritHolder as malicious.
proc flag*(
    consensus: Consensus,
    state: var State,
    removal: MeritRemoval
) {.forceCheck: [].} =
    #Make sure there's a seq.
    if not consensus.malicious.hasKey(removal.holder):
        consensus.malicious[removal.holder] = @[]

    #Add the MeritRemoval.
    try:
        consensus.malicious[removal.holder].add(removal)
    except KeyError as e:
        doAssert(false, "Couldn't add a MeritRemoval to a seq we've confirmed exists: " & e.msg)

    #Reclaulcate the affected verified Transactions.
    var
        elem: Element
        verif: Verification
        status: TransactionStatus

    for e in consensus.db.loadOutOfEpochs(removal.holder) + 1 ..< consensus[removal.holder].height:
        try:
            elem = consensus[removal.holder][e]
            if not (elem of Verification):
                continue
            verif = cast[Verification](elem)
            status = consensus.getStatus(verif.hash)
        except IndexError as e:
            doAssert(false, "Either couldn't get an Element in Epochs or the Status for the Transaction it verifies: " & e.msg)

        if status.verified:
            var merit: int = 0
            for verifier in status.verifiers:
                if not consensus.malicious.hasKey(verifier):
                    merit += state[verifier]

            if merit < state.protocolThresholdAt(status.epoch):
                consensus.unverify(state, verif.hash, status)

proc checkMalicious*(
    consensus: Consensus,
    verif: SignedVerification
) {.forceCheck: [
    GapError,
    DataExists,
    MaliciousMeritHolder
].} =
    #This method is called before the Element is added.
    #Only when we add the Element, do we verify its signature.
    #This method will fail to aggregate unless we set its AggregationInfo now.
    try:
        verif.signature.setAggregationInfo(
            newBLSAggregationInfo(
                verif.holder,
                verif.serializeSign()
            )
        )
    except BLSError as e:
        doAssert(false, "Failed to create a BLS Aggregation Info: " & e.msg)

    try:
        consensus[verif.holder].checkMalicious(verif)
    except GapError as e:
        fcRaise e
    except DataExists as e:
        fcRaise e
    except MaliciousMeritHolder as e:
        #Manually recreate the Exception since fcRaise wouldn't include the MeritRemoval.
        raise newMaliciousMeritHolder(
            e.msg,
            e.removal
        )

#Register a Transaction.
proc register*(
    consensus: Consensus,
    transactions: Transactions,
    state: var State,
    tx: Transaction,
    blockNum: int
) {.forceCheck: [].} =
    #Create the status.
    var status: TransactionStatus = newTransactionStatusObj(blockNum + 6)

    for input in tx.inputs:
        #Check if this Transaction's parent was beatem.
        try:
            if (
                (not status.beaten) and
                (not (tx of Claim)) and
                (not ((tx of Data) and cast[Data](tx).isFirstData)) and
                (consensus.getStatus(input.hash).beaten)
            ):
                status.beaten = true
        except IndexError:
            doAssert(false, "Parent Transaction doesn't have a status.")

        #Check for competing Transactions.
        var spenders: seq[Hash[384]] = transactions.loadSpenders(input)
        if spenders.len != 1:
            status.defaulting = true

            #If there's a competing Transaction, mark competitors as needing to default.
            #This will run for every input with multiple spenders.
            if status.defaulting:
                for spender in spenders:
                    if spender == tx.hash:
                        continue

                    try:
                        consensus.getStatus(spender).defaulting = true
                    except IndexError:
                        doAssert(false, "Competing Transaction doesn't have a status despite being marked as a spender.")

    #If there were previously unknown Verifications, apply them.
    if consensus.unknowns.hasKey(tx.hash):
        try:
            for verifier in consensus.unknowns[tx.hash]:
                status.verifiers.add(verifier)

            #Delete from the unknowns table.
            consensus.unknowns.del(tx.hash)

            #Since we added Verifiers, calculate the Merit.
            consensus.calculateMerit(state, tx.hash, status)
        except KeyError as e:
            doAssert(false, "Couldn't get unknown Verifications for a Transaction with unknown Verifications: " & e.msg)

    #Set the status.
    consensus.setStatus(tx.hash, status)

#Handle unknown Verifications.
proc handleUnknown(
    consensus: Consensus,
    verif: Verification
) {.forceCheck: [].} =
    if not consensus.unknowns.hasKey(verif.hash):
        consensus.unknowns[verif.hash] = newSeq[BLSPublicKey]()

    try:
        consensus.unknowns[verif.hash].add(verif.holder)
    except KeyError as e:
        doAssert(false, "Couldn't add a Merit Holder to a seq we've confirmed to exist: " & e.msg)

#Add a Verification.
proc add*(
    consensus: Consensus,
    state: var State,
    verif: Verification,
    txExists: bool
) {.forceCheck: [
    ValueError,
    GapError,
    DataExists
].} =
    try:
        consensus[verif.holder].add(verif)
    except GapError as e:
        fcRaise e
    except DataExists as e:
        fcRaise e
    except MaliciousMeritHolder as e:
        raise newException(ValueError, "Tried to add an Element from a Block which would cause a MeritRemoval: " & e.msg)

    if not txExists:
        consensus.handleUnknown(verif)
    else:
        consensus.update(state, verif.hash, verif.holder)

#Add a SignedVerification.
proc add*(
    consensus: Consensus,
    state: var State,
    verif: SignedVerification
) {.forceCheck: [
    ValueError,
    GapError
].} =
    try:
        consensus[verif.holder].add(verif)
    except ValueError as e:
        fcRaise e
    except GapError as e:
        fcRaise e
    except DataExists as e:
        doAssert(false, "Tried to add a SignedVerification which caused was already added. This should've been checked via checkMalicious before hand: " & e.msg)
    except MaliciousMeritHolder as e:
        doAssert(false, "Tried to add a SignedVerification which caused a MeritRemoval. This should've been checked via checkMalicious before hand: " & e.msg)

    consensus.update(state, verif.hash, verif.holder)

#Add a MeritRemoval.
proc add*(
    consensus: Consensus,
    state: var State,
    mr: MeritRemoval
) {.forceCheck: [
    ValueError
].} =
    #If this is a partial MeritRemoval, make sure the first Element is already archived on this Consensus DAG.
    if mr.partial:
        if mr.element1.nonce < consensus[mr.holder].archived:
            raise newException(ValueError, "Partial MeritRemoval references unarchived Element.")

        try:
            if mr.element1 != consensus[mr.holder][mr.element1.nonce]:
                raise newException(ValueError, "Partial MeritRemoval references Element not on this chain.")
        except IndexError as e:
            doAssert(false, "Failed to load an archived Element: " & e.msg)

    #Same nonce.
    if mr.element1.nonce == mr.element2.nonce:
        if mr.element1 == mr.element2:
            raise newException(ValueError, "Same Nonce MeritRemoval uses the same Elements.")
    #Verified competing elements.
    else:
        doAssert(false, "Verified competing MeritRemovals aren't supported.")

    consensus.flag(state, mr)

#Add a SignedMeritRemoval.
proc add*(
    consensus: Consensus,
    state: var State,
    mr: SignedMeritRemoval
) {.forceCheck: [
    ValueError
].} =
    #Verify the MeritRemoval's signature.
    try:
        mr.signature.setAggregationInfo(mr.agInfo)
        if not mr.signature.verify():
            raise newException(ValueError, "Invalid MeritRemoval signature.")
    except BLSError as e:
        doAssert(false, "Failed to verify the MeritRemoval's signature: " & e.msg)

    #Add the MeritRemoval.
    try:
        consensus.add(state, cast[MeritRemoval](mr))
    except ValueError as e:
        fcRaise e

#Archive a MeritRemoval. This:
#- Sets the MeritHolder's height to 1 above the archived height.
#- Saves the element to its position.
proc archive*(
    consensus: Consensus,
    mr: MeritRemoval
) {.forceCheck: [].} =
    #Grab the MeritHolder.
    var mh: MeritHolder
    try:
        mh = consensus[mr.holder]
    except KeyError as e:
        doAssert(false, "Couldn't get the MeritHolder who caused a valid MeritRemoval: " & e.msg)

    #Set the MeritRemoval's nonce.
    try:
        mr.nonce = mh.archived + 1
    except FinalAttributeError as e:
        doAssert(false, "Set a final attribute twice when archicing a MeritRemoval: " & e.msg)

    #Delete reverted elements (except the first which we overwrite).
    for e in mh.archived + 2 ..< mh.height:
        consensus.db.del(mr.holder, e)

    #Correct the height.
    mh.height = mh.archived + 2

    #Save the element.
    consensus.db.save(mr)

    #Delete the MeritRemovals from the malicious table.
    consensus.malicious.del(mr.holder)

#Get a Transaction's unfinalized parents.
proc getUnfinalizedParents(
    consensus: Consensus,
    tx: Transaction
): seq[Hash[384]] {.forceCheck: [].} =
    #If this Transaction doesn't have inputs with statuses, don't do anything.
    if not (
        (tx of Claim) or
        (
            (tx of Data) and
            (cast[Data](tx).isFirstData)
        )
    ):
        #Make sure every input was already finalized.
        for input in tx.inputs:
            try:
                if consensus.getStatus(input.hash).merit == -1:
                    result.add(input.hash)
            except IndexError as e:
                doAssert(false, "Couldn't get the Status of a Transaction used as an input to one out of Epochs: " & e.msg)

#For each provided Record, archive all Elements from the account's last archived to the provided nonce.
proc archive*(
    consensus: Consensus,
    state: var State,
    shifted: Epoch,
    popped: Epoch
) {.forceCheck: [].} =
    #Iterate over every Record.
    for record in shifted.records:
        #Make sure this MeritHolder has Elements to archive.
        if consensus[record.key].archived == consensus[record.key].height - 1:
            doAssert(false, "Tried to archive Elements from a MeritHolder without any pending Elements.")

        #Make sure this MeritHolder has enough Elements.
        if record.nonce >= consensus[record.key].height:
            doAssert(false, "Tried to archive more Elements than this MeritHolder has pending.")

        #Delete the old signatures.
        for e in consensus[record.key].archived + 1 .. record.nonce:
            consensus[record.key].signatures.del(e)

        #Reset the Merkle.
        consensus[record.key].merkle = newMerkle()
        for e in record.nonce + 1 ..< consensus[record.key].height:
            try:
                consensus[record.key].addToMerkle(consensus[record.key][e])
            except IndexError as e:
                doAssert(false, "Couldn't get an element we know we have: " & e.msg)

        #Update the archived field.
        consensus[record.key].archived = record.nonce

        #Update the DB.
        consensus.db.save(record.key, record.nonce)

    #Delete every new Hash in Epoch from unmentioned.
    for hash in shifted.hashes.keys():
        consensus.unmentioned.del(hash)
    #Update the Epoch for every unmentioned Epoch.
    for hash in consensus.unmentioned.keys():
        consensus.incEpoch(hash)
        consensus.db.addUnmentioned(hash)

    #Save every popped record nonce.
    for record in popped.records:
        consensus.db.saveOutOfEpochs(record.key, record.nonce)

    #Transactions finalized out of order.
    var outOfOrder: Table[Hash[384], bool] = initTable[Hash[384], bool]()
    #Mark every hash in this Epoch as out of Epochs.
    for hash in popped.hashes.keys():
        #Skip Transaction we verified out of order.
        if outOfOrder.hasKey(hash):
            continue

        var parents: seq[Hash[384]] = @[hash]
        while parents.len != 0:
            #Grab the last parent.
            var parent: Hash[384] = parents.pop()

            #Skip this Transaction if we already verified it.
            if outOfOrder.hasKey(parent):
                continue

            #Grab the Transaction.
            var tx: Transaction
            try:
                tx = consensus.functions.transactions.getTransaction(parent)
            except IndexError as e:
                doAssert(false, "Couldn't get a Transaction that's out of Epochs: " & e.msg)

            #Grab this Transaction's unfinalized parents.
            var newParents: seq[Hash[384]] = consensus.getUnfinalizedParents(tx)

            #If all the parents are finalized, finalize this Transaction.
            if newParents.len == 0:
                consensus.finalize(state, parent)
                outOfOrder[parent] = true
            else:
                #Else, add back this Transaction, and then add the new parents.
                parents.add(parent)
                parents &= newParents

    #Reclaulcate every close Status.
    var toDelete: seq[Hash[384]] = @[]
    for hash in consensus.close.keys():
        var status: TransactionStatus
        try:
            status = consensus.getStatus(hash)
        except IndexError:
            doAssert(false, "Couldn't get the status of a Transaction that's close to being verified: " & $hash)

        #Remove finalized Transactions.
        if status.merit != -1:
            toDelete.add(hash)
            continue

        #Recalculate Merit.
        consensus.calculateMerit(state, hash, status)
        #Remove verified Transactions.
        if status.verified:
            toDelete.add(hash)
            continue

    #Delete all close hashes marked for deletion.
    for hash in toDelete:
        consensus.close.del(hash)
