discard """
Epochs Split Test. Verifies that:
    - 2 Verifications
    - For the same Transaction
    - A block apart
Result in 500/500 when the Transaction first appeared.
"""

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
        blockchain: Blockchain = newBlockchain(db, "EPOCH_SPLIT_TEST", 1, "".pad(48).toHash(384))
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
        hash: Hash[384] = "".pad(48, char(128)).toHash(384)
        #MinerWallets.
        miners: seq[MinerWallet] = @[
            newMinerWallet(),
            newMinerWallet()
        ]
        #SignedVerification object.
        verif: SignedVerification
        #Rewards.
        rewards: seq[Reward]

    #Init the Function Box.
    functions.init(addr transactions)

    #Register the Transaction.
    var tx: Transaction = Transaction()
    tx.hash = hash
    transactions.transactions[tx.hash] = tx
    consensus.register(transactions, state, tx, 0)

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

        #Create the Verification.
        verif = newSignedVerificationObj(hash)
        miner.sign(verif, 0)

        #Add the Verification.
        consensus.add(state, verif)

        #Shift on the record.
        rewards = epochs.shift(
            consensus,
            @[],
            @[
                newMeritHolderRecord(
                    miner.publicKey,
                    0,
                    hash
                )
            ]
        ).calculate(state)
        assert(rewards.len == 0)

    #Shift 3 over.
    for _ in 0 ..< 3:
        rewards = epochs.shift(consensus, @[], @[]).calculate(state)
        assert(rewards.len == 0)

    #Next shift should result in a Rewards of key 0, 500 and key 1, 500.
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

    echo "Finished the Database/Merit/Epochs Split Test."
