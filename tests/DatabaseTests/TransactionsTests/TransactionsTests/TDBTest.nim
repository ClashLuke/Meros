#Transactions DB Test.

#Util lib.
import ../../../../src/lib/Util

#Hash lib.
import ../../../../src/lib/Hash

#Wallet libs.
import ../../../../src/Wallet/HDWallet
import ../../../../src/Wallet/MinerWallet

#MeritHolderRecord object.
import ../../../../src/Database/common/objects/MeritHolderRecordObj

#Consensus lib.
import ../../../../src/Database/Consensus/Consensus

#Merit lib.
import ../../../../src/Database/Merit/Merit

#Transactions lib.
import ../../../../src/Database/Transactions/Transactions

#Test Database lib.
import ../../TestDatabase

#Compare Transactions lib.
import ../CompareTransactions

#Tables lib.
import tables

#Random standard lib.
import random

#Seed random.
randomize(getTime())

discard """
On Transactions creation:
    Scan the Blockchain for the records in Epochs.
    Iterate over every Element archived by these records.
    If the Element is a Verification, load the Transaction it verified.

    Scan the Blockchain for the records in Epochs.
    Grab every mentioned MeritHolder.
    For each MeritHolder, grab their archived tip and tips in Epochs.
    Load every Verification from their archived tip to their height, with the State used at the time.

On Transaction addition:
    Save the Transaction to `HASH` (prefixed with a byte of the TransactionType).
    If the Transaction is a Mint, save the MintOutput to `HASH + char(0)`.

On Transaction verification:
    Delete every UTXO it spends from the Database.
    Save every SendOutput to `HASH + char(OUTPUT_NONCE)`.
    Save "" to `HASH + "vrf"`.

On Transactions archival:
    Iterate over every Element archived by the Epoch's records.
    Clear transactions mentioned in the archived Elements from the cache.
    Save the newly archived tip to `KEY + "mh"`
"""

var
    #Database.
    db: DB = newTestDatabase()

    #Consensus.
    consensus: Consensus = newConsensus(db)
    #Merit.
    merit: Merit = newMerit(
        db,
        consensus,
        "BLOCKCHAIN_TEST",
        30,
        "".pad(48),
        100
    )
    #Transactions.
    transactions: Transactions = newTransactions(
        db,
        consensus,
        merit,
        "".pad(96, "11"),
        "".pad(96, "33")
    )

    #MeritHolders.
    holders: seq[MinerWallet] = @[]
    #Accounts.
    wallets: seq[HDWallet] = @[]

    #UTXOs.
    utxos: Table[string, seq[SendInput]] = initTable[string, seq[SendInput]]()

#Test the Transactions against the reloaded Transactions.
proc test() =
    #Reload the Transactions.
    var reloaded: Transactions = newTransactions(
        db,
        consensus,
        merit,
        $transactions.difficulties.send,
        $transactions.difficulties.data
    )

    #Compare the Transactionss.
    compare(transactions, reloaded)

#Adds a Block, containing the passed records.
proc addBlock() =
    var
        #Records.
        records: seq[MeritHolderRecord] = @[]
        #Holders we're assigning new Merit.
        paying: seq[BLSPublicKey]
        #Create the Miners objects.
        miners: seq[Miner] = @[]
        #Remaining amount of Merit.
        remaining: int = 100

    #Create the Records for every MeritHolder.
    for holder in holders:
        if consensus[holder.publicKey].archived + 1 < consensus[holder.publicKey].height:
            records.add(
                newMeritHolderRecord(
                    holder.publicKey,
                    consensus[holder.publicKey].height - 1,
                    "".pad(48).toHash(384)
                )
            )

    #Grab holders to pay.
    for holder in holders:
        #Select any holders with 0 Merit.
        if merit.state[holder.publicKey] == 0:
            paying.add(holder.publicKey)
        #Else, give them a 50% chance.
        else:
            if rand(100) > 50:
                paying.add(holder.publicKey)
    #If we didn't add any holders, pick one at random.
    if paying.len == 0:
        paying.add(holders[rand(holders.len - 1)].publicKey)

    for i in 0 ..< paying.len:
        #Set the amount to pay the miner.
        var amount: int = rand(remaining - 1) + 1

        #Make sure everyone gets at least 1 and we don't go over 100.
        if (remaining - amount) < (paying.len - i):
            amount = 1

        #But if this is the last account...
        if i == paying.len - 1:
            amount = remaining

        #Add the miner.
        miners.add(
            newMinerObj(
                paying[i],
                amount
            )
        )

        remaining -= amount

    #Create the new Block.
    var newBlock: Block = newBlockObj(
        merit.blockchain.height,
        merit.blockchain.tip.header.hash,
        nil,
        records,
        newMinersObj(miners),
        getTime(),
        0
    )

    #Mine it.
    while not merit.blockchain.difficulty.verify(newBlock.header.hash):
        inc(newBlock)

    #Add it,
    var epoch: Epoch = merit.processBlock(consensus, newBlock)

    #Manually clear the difficulty.
    merit.blockchain.difficulty = newDifficultyObj(
        merit.blockchain.difficulty.start,
        merit.blockchain.difficulty.endBlock,
        "".pad(48).toHash(384)
    )

    #Archive the Records.
    consensus.archive(newBlock.records)
    transactions.archive(consensus, epoch)

#Add Verifications for an Transaction.
proc verify(
    hash: Hash[384],
    mustVerify: bool = false
) =
    #List of MeritHolders being used to verify this hash.
    var verifiers: seq[MinerWallet]
    if mustVerify:
        verifiers = holders
    else:
        #Grab holders to verify wuth.
        for holder in holders:
            if rand(100) > 50:
                verifiers.add(holder)
        #If we didn't add any holders, pick one at random.
        if verifiers.len == 0:
            verifiers.add(holders[rand(holders.len - 1)])

    #Verify with each Verifier.
    for verifier in verifiers:
        var verif: SignedVerification = newSignedVerificationObj(hash)
        verifier.sign(verif, consensus[verifier.publicKey].height)
        consensus.add(verif)
        transactions.verify(verif, merit.state[verifier.publicKey], merit.state.live)

#Create a random amount of MeritHolders.
for _ in 0 ..< rand(25) + 1:
    holders.add(newMinerWallet())
#Assign them enough Meit to verify things.
for _ in 0 ..< 13:
    addBlock()

#Iterate over 20 'rounds'.
for _ in 0 ..< 20:
    #Create a random amount of Wallets.
    for _ in 0 ..<  rand(2) + 1:
        wallets.add(newHDWallet().next())
        utxos[wallets[^1].publicKey.toString()] = @[]

    #Create Transactions and verify them.
    for e in 0 ..< rand(10):
        #Grab a random Wallet.
        var
            sender: int = rand(wallets.len - 1)
            wallet: Wallet = wallets[sender]

        #Create a Send.
        if rand(1) == 0:
            var
                #Decide how much to Send.
                amount: uint64 = uint64(rand(10000))
                #Current balance.
                balance: uint64 = 0
            #Calculate the balance.
            for input in utxos[wallet.publicKey.toString()]:
                balance += transactions[input.hash].outputs[input.nonce].amount

            #Fund them if they need funding.
            if balance <= amount:
                #Create the Mint.
                var
                    mintee: MinerWallet = newMinerWallet()
                    mintHash: Hash[384] = transactions.mint(mintee.publicKey, amount - balance + uint64(rand(5000)))

                #Create the Claim.
                var claim: Claim = newClaim(
                    cast[Mint](transactions[mintHash]),
                    wallet.publicKey
                )
                mintee.sign(claim)
                transactions.add(claim)
                verify(claim.hash, true)

                #Update balance.
                balance += transactions[mintHash].outputs[0].amount

                #Add the UTXO.
                utxos[wallet.publicKey.toString()].add(newSendInput(claim.hash, 0))

            #Create the Send.
            var send: Send = newSend(
                utxos[wallet.publicKey.toString()],
                @[
                    newSendOutput(
                        #Use a limited subset to increase the odds a Mint isn't needed.
                        wallets[min(rand(5 - 1), wallets.len - 1)].publicKey,
                        amount
                    ),
                    newSendOutput(
                        wallet.publicKey,
                        balance - amount
                    )
                ])
            wallet.sign(send)
            send.mine(transactions.difficulties.send)
            transactions.add(send)
            verify(send.hash)

            #Update the existing UTXOs.
            utxos[wallet.publicKey.toString()] = @[]

            #If the Send was verified, add its change UTXO.
            if transactions[send.hash].verified:
                utxos[wallet.publicKey.toString()].add(
                    newSendInput(
                        send.hash,
                        1
                    )
                )

        #Create a Data.
        else:
            discard

    #Create a random amount of MeritHolders.
    for i in 0 ..< rand(3):
        holders.add(newMinerWallet())

    #Mine a Block.
    addBlock()

    #Test the Transactionss.
    test()

echo "Finished the Database/Transactions/Transactions/DB Test."
