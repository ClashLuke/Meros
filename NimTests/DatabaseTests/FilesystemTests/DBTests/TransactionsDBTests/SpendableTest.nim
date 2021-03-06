#TransactionsDB Spendable Test.
#Tests saving UTXOs, checking which UYTXOs an account can spend, and deleting UTXOs.

#Util lib.
import ../../../../../src/lib/Util

#Hash lib.
import ../../../../../src/lib/Hash

#Wallet lib.
import ../../../../../src/Wallet/Wallet

#TransactionDB lib.
import ../../../../../src/Database/Filesystem/DB/TransactionsDB

#Input/Output objects.
import ../../../../../src/Database/Transactions/objects/TransactionObj

#Send lib.
import ../../../../../src/Database/Transactions/Send

#Test Database lib.
import ../../../TestDatabase

#Algorithm standard lib.
import algorithm

#Tables lib.
import tables

#Random standard lib.
import random

proc test*() =
    #Seed Random via the time.
    randomize(int64(getTime()))

    var
        #DB.
        db = newTestDatabase()
        #Wallets.
        wallets: seq[Wallet] = @[]

        #Outputs.
        outputs: seq[SendOutput] = @[]
        #Send.
        send: Send

        #Public Key -> Spendable Outputs.
        spendable: Table[EdPublicKey, seq[SendInput]] = initTable[EdPublicKey, seq[SendInput]]()
        #Inputs.
        inputs: seq[SendInput] = @[]
        #Loaded Spendable.
        loaded: seq[SendInput] = @[]
        #Sends.
        sends: seq[Send] = @[]
        #Who can spend a SendInput.
        spenders: Table[string, EdPublicKey] = initTable[string, EdPublicKey]()

    proc inputSort(
        x: SendInput,
        y: SendInput
    ): int =
        if x.hash < y.hash:
            result = -1
        elif x.hash > y.hash:
            result = 1
        else:
            if x.nonce < y.nonce:
                result = -1
            elif x.nonce > y.nonce:
                result = 1
            else:
                result = 0

    proc compare() =
        #Test each spendable.
        for key in spendable.keys():
            loaded = db.loadSpendable(key)

            spendable[key].sort(inputSort)
            loaded.sort(inputSort)

            assert(spendable[key].len == loaded.len)
            for i in 0 ..< spendable[key].len:
                assert(spendable[key][i].hash == loaded[i].hash)
                assert(spendable[key][i].nonce == loaded[i].nonce)

    #Generate 10 wallets.
    for _ in 0 ..< 10:
        wallets.add(newWallet(""))

    #Test 100 Transactions.
    for _ in 0 .. 100:
        outputs = newSeq[SendOutput](rand(254) + 1)
        for o in 0 ..< outputs.len:
            outputs[o] = newSendOutput(
                wallets[rand(10 - 1)].publicKey,
                0
            )

        send = newSend(@[], outputs)
        db.save(send)

        if rand(2) != 0:
            db.verify(send)
            for o in 0 ..< outputs.len:
                if not spendable.hasKey(outputs[o].key):
                    spendable[outputs[o].key] = @[]
                spendable[outputs[o].key].add(newSendInput(send.hash, o))
                spenders[send.hash.toString() & char(o)] = outputs[o].key

        compare()

        #Spend outputs.
        for key in spendable.keys():
            if spendable[key].len == 0:
                continue

            inputs = @[]
            var i: int = 0
            while true:
                if rand(1) == 0:
                    inputs.add(spendable[key][i])
                    spendable[key].delete(i)
                else:
                    inc(i)

                if i == spendable[key].len:
                    break

            if inputs.len != 0:
                var outputKey: EdPublicKey = wallets[rand(10 - 1)].publicKey
                send = newSend(inputs, newSendOutput(outputKey, 0))
                db.save(send)
                db.verify(send)
                sends.add(send)

                if not spendable.hasKey(outputKey):
                    spendable[outputKey] = @[]
                spendable[outputKey].add(newSendInput(send.hash, 0))
                spenders[send.hash.toString() & char(0)] = outputKey

        compare()

        #Unverify a Send.
        if sends.len != 0:
            var s: int = rand(sends.high)
            db.unverify(sends[s])
            for input in sends[s].inputs:
                spendable[
                    spenders[input.hash.toString() & char(cast[SendInput](input).nonce)]
                ].add(cast[SendInput](input))

            for o1 in 0 ..< sends[s].outputs.len:
                var output: SendOutput = cast[SendOutput](sends[s].outputs[o1])
                for o2 in 0 ..< spendable[output.key].len:
                    if (
                        (spendable[output.key][o2].hash == sends[s].hash) and
                        (spendable[output.key][o2].nonce == o1)
                    ):
                        spendable[output.key].delete(o2)
                        break

        compare()

    echo "Finished the Database/Filesystem/DB/TransactionsDB/Spendable Test."
