#Errors lib.
import ../../lib/Errors

#Util lib.
import ../../lib/Util

#Hash lib.
import ../../lib/Hash

#MinerWallet lib (for BLSPublicKey's toString).
import ../../Wallet/MinerWallet

#Consensus lib.
import ../Consensus/Consensus

#Merit DB lib.
import ../Filesystem/DB/MeritDB

#MeritHolderRecord object.
import ../common/objects/MeritHolderRecordObj

#Block, Blockcain, and State lib.
import Block
import Blockchain
import State

#Epoch objects.
import objects/EpochsObj
export EpochsObj

#Sequtils standard lib (used to remove Rewards).
import sequtils

#Algorithm standard lib (used to sort Rewards).
import algorithm

#Tables standard lib.
import tables

#This shift does four things:
# - Adds the newest set of Verifications.
# - Stores the oldest Epoch to be returned.
# - Removes the oldest Epoch from Epochs.
# - Saves the MeritHolderRecords in the Epoch to-be-returned to the Database.
#If tips is provided, which it is when loading from the DB, those are used instead of holder.archived.
proc shift*(
    epochs: var Epochs,
    consensus: Consensus,
    records: seq[MeritHolderRecord],
    tips: TableRef[string, int] = nil
): Epoch {.forceCheck: [].} =
    var
        #New Epoch for any Verifications belonging to Transactions that aren't in an older Epoch.
        newEpoch: Epoch = newEpoch(records)
        #Loop variable of what Element to start with.
        start: int
        #Verifications we're handling.
        verifs: seq[Verification]

    #Loop over each Verification.
    for record in records:
        #If we were passed tips, use those for the starting point.
        if not tips.isNil:
            try:
                start = tips[record.key.toString()]
            except KeyError as e:
                doAssert(false, "Reloading Epochs from the DB using invalid tips: " & e.msg)
        #Else, use the holder's archived.
        else:
            start = consensus[record.key].archived

        #Grab the Verifs.
        try:
            verifs = consensus[record.key][start .. record.nonce]
        #This will be thrown if we access a nonce too high, which shouldn't happen as we check a Block only has valid tips.
        except IndexError as e:
            doAssert(false, "An invalid tip was passed to shift: " & e.msg)

        #Iterate over every Verification.
        for verif in verifs:
            #Try adding this hash to an existing Epoch.
            try:
                epochs.add(verif.hash.toString(), verif.holder)
            #If it wasn't in any existing Epoch, add it to the new one.
            except NotInEpochs:
                newEpoch.add(verif.hash.toString(), verif.holder)

        #If we were passed a set of tips, update them.
        if not tips.isNil:
            tips[record.key.toString()] = record.nonce

    #Return the popped Epoch.
    result = epochs.shift(newEpoch, tips.isNil)

#Constructor. Below shift as it calls shift.
proc newEpochs*(
    db: DB,
    consensus: Consensus,
    blockchain: Blockchain
): Epochs {.forceCheck: [].} =
    #Create the Epochs objects.
    result = newEpochsObj(db)

    #Regenerate the Epochs.
    var
        #Seq of every holder.
        holders: seq[string]
        #Table of every archived tip before the current Epochs.
        tips: TableRef[string, int] = newTable[string, int]()

    try:
        holders = db.loadHolders()
    except DBReadError:
        #If there are no holders, there's no mined Blocks and therefore no Epochs to regenerate.
        holders = @[]

    #We don't just return in the above except in case an empty holders is saved to the DB.
    #That should be impossible, as the State, as of right now, only saves the holders once it has some.
    #That said, if we change how the State operates the DB, it shouldn't break this.
    if holders.len == 0:
        return

    #Use the Holders string from the State.
    for holder in holders:
        #Load their tip.
        try:
            tips[holder] = db.loadHolderEpoch(holder)
        except DBReadError:
            #If this failed, it's because they have Merit but don't have Elements older than 5 blocks.
            tips[holder] = 0

    #Shift the last 10 blocks. Why?
    #We want to regenerate the Epochs for the last 5, but we need to regenerate the 5 before that so late consensus aren't labelled as first appearances.
    var start: int = 10
    #If the blockchain is smaller than 10, load every block.
    if blockchain.height < 10:
        start = blockchain.height

    try:
        for i in countdown(start, 1):
            discard result.shift(
                consensus,
                blockchain[blockchain.height - i].records,
                tips
            )
    except IndexError as e:
        doAssert(false, "Couldn't shift the last blocks of the chain: " & e.msg)

#Calculate what share each holder deserves of the minted Meros.
proc calculate*(
    epoch: Epoch,
    state: var State
): seq[Reward] {.forceCheck: [].} =
    #If the epoch is empty, do nothing.
    if epoch.hashes.len == 0:
        return @[]

    var
        #Total Merit behind an Transaction.
        weight: int
        #Score of a holder.
        scores: Table[string, uint64] = initTable[string, uint64]()
        #Total score.
        total: uint64
        #Total normalized score.
        normalized: int

    #Find out how many Verifications for verified Transactions were created by each Merit Holder.
    for tx in epoch.hashes.keys():
        #Clear the loop variable.
        weight = 0

        try:
            #Iterate over every holder who verified a tx.
            for holder in epoch.hashes[tx]:
                #Add their Merit to the Transaction's weight.
                weight += state[holder]
        except KeyError as e:
            doAssert(false, "Couldn't grab the verifiers for a hash in the Epoch grabbed from epoch.hashes.keys(): " & e.msg)

        #Make sure the Transaction was verified.
        if weight < ((state.live div 2) + 1):
            continue

        #If it was, increment every verifier's score.
        var holder: string
        try:
            for holderLoop in epoch.hashes[tx]:
                holder = holderLoop.toString()
                if not scores.hasKey(holder):
                    scores[holder] = 0
                scores[holder] += 1
        except KeyError as e:
            doAssert(false, "Either couldn't grab the verifiers for an Transaction in the Epoch or the score of a holder: " & e.msg)

    #Multiply every score by how much Merit the holder has.
    try:
        for holder in scores.keys():
            scores[holder] = scores[holder] * uint64(state[holder])
            #Add the update score to the total.
            total += scores[holder]
    except KeyError as e:
        doAssert(false, "Couldn't update a holder's score despite grabbing the holder by scores.keys(): " & e.msg)

    #Turn the table into a seq.
    result = newSeq[Reward]()
    try:
        for holder in scores.keys():
            result.add(
                newReward(
                    holder,
                    scores[holder]
                )
            )
    except KeyError as e:
        doAssert(false, "Couldn't grab the score of a holder grabbed from scores.keys(): " & e.msg)

    #Sort them by greatest score.
    result.sort(
        func (
            x: Reward,
            y: Reward
        ): int =
            if x.score > y.score:
                result = 1
            elif x.score == y.score:
                for b in 0 ..< x.key.len:
                    if x.key[b] > y.key[b]:
                        return 1
                    elif x.key[b] == y.key[b]:
                        continue
                    else:
                        return -1
                doAssert(false, "Epochs generated two rewards for the same key.")
            else:
                result = -1
        , SortOrder.Descending
    )

    #Delete everything after 100.
    if result.len > 100:
        result.delete(100, result.len - 1)

    #Normalize each holder to a share of 1000.
    for i in 0 ..< result.len:
        result[i].score = result[i].score * 1000 div total
        normalized += int(result[i].score)

    #If the score isn't a perfect 1000, attribute everything left over to the top verifier.
    if normalized < 1000:
        result[0].score += uint64(1000 - normalized)
