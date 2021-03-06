#Epochs Tie Break Test. Verifies that two rewards with the same amount place the reward with the higher key first.

#Util lib.
import ../../../../src/lib/Util

#Hash lib.
import ../../../../src/lib/Hash

#MinerWallet lib.
import ../../../../src/Wallet/MinerWallet

#MeritHolderRecord object.
import ../../../../src/Database/common/objects/MeritHolderRecordObj

#Transactions lib.
import ../../../../src/Database/Transactions/Transactions

#Consensus lib.
import ../../../../src/Database/Consensus/Consensus

#Merit lib.
import ../../../../src/Database/Merit/Merit

#Merit Testing functions.
import ../TestMerit

#Tables standard lib.
import tables

proc test*() =
    var
        #Functions.
        functions: GlobalFunctionBox = newGlobalFunctionBox()
        #Database Function Box.
        db: DB = newTestDatabase()
        #Consensus.
        consensus: Consensus = newConsensus(
            functions,
            db,
            Hash[384](),
            Hash[384]()
        )
        #Blockchain.
        blockchain: Blockchain = newBlockchain(db, "EPOCH_TIE_BREAK_TEST", 1, "".pad(48).toHash(384))
        #State.
        state: State = newState(db, 100, blockchain.height)
        #Epochs.
        epochs: Epochs = newEpochs(db, consensus, blockchain)
        #Transactions.
        transactions: Transactions = newTransactions(
            db,
            consensus,
            blockchain
        )

        #Hash.
        hash: Hash[384]
        #MinerWallets.
        miners: seq[MinerWallet] = @[
            newMinerWallet(),
            newMinerWallet()
        ]
        #SignedVerification object.
        verif: SignedVerification
        #MeritHolderRecords.
        records: seq[MeritHolderRecord] = @[]
        #Rewards.
        rewards: seq[Reward]

    #Init the Function Box.
    functions.init(addr transactions)

    for miner in miners:
        #Give the miner Merit.
        state.processBlock(
            blockchain,
            newBlankBlock(
                miners = newMinersObj(@[
                    newMinerObj(
                        miner.publicKey,
                        100
                    )
                ])
            )
        )

    for h in 1 .. 2:
        #Generate the hash.
        hash = "".pad(48, char(h)).toHash(384)

        #Register the Transaction.
        var tx: Transaction = Transaction()
        tx.hash = hash
        transactions.transactions[tx.hash] = tx
        consensus.register(transactions, state, tx, 0)

        #Clear the records.
        records = @[]
        for miner in miners:
            #Create the Verification.
            verif = newSignedVerificationObj(hash)
            miner.sign(verif, consensus[miner.publicKey].height)

            #Add the Verification.
            consensus.add(state, verif)

            #Add the record.
            records.add(
                newMeritHolderRecord(
                    miner.publicKey,
                    consensus[miner.publicKey].height - 1,
                    hash
                )
            )

        #Shift on the records.
        rewards = epochs.shift(
            consensus,
            @[],
            records
        ).calculate(state)
        assert(rewards.len == 0)

    #Shift 3 over.
    for _ in 0 ..< 3:
        rewards = epochs.shift(consensus, @[], @[]).calculate(state)
        assert(rewards.len == 0)

    #Next two shifts should be the same; the higher key is first, and both keys have an amount of 500.
    for _ in 1 .. 2:
        rewards = epochs.shift(consensus, @[], @[]).calculate(state)

        #Veirfy the length.
        assert(rewards.len == 2)

        #Verify each key is unique and one of our keys.
        for r1 in 0 ..< rewards.len:
            for r2 in 0 ..< rewards.len:
                if r1 == r2:
                    continue
                assert(rewards[r1].key != rewards[r2].key)

            for m in 0 ..< miners.len:
                if rewards[r1].key == miners[m].publicKey:
                    break

                if m == miners.len - 1:
                    assert(false)

        #Verify the scores.
        assert(rewards[0].score == 500)
        assert(rewards[1].score == 500)

        #Verify the first key is higher than the second key.
        var
            key0: string = rewards[0].key.toString()
            key1: string = rewards[1].key.toString()
            isHigher: bool = false
        for b in 0 ..< key0.len:
            if key0[b] > key1[b]:
                isHigher = true
                break
            elif key0[b] == key1[b]:
                continue
            else:
                break
        assert(isHigher)

    echo "Finished the Database/Merit/Epochs Tie Break Test."
