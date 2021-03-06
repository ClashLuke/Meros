include MainTransactions

proc mainPersonal() {.forceCheck: [].} =
    {.gcsafe.}:
        #Get the Wallet.
        functions.personal.getWallet = proc (): Wallet {.inline, forceCheck: [].} =
            wallet

        #Set the Wallet's Mnemonic.
        functions.personal.setMnemonic = proc (
            mnemonic: string,
            password: string
        ) {.forceCheck: [
            ValueError
        ].} =
            if mnemonic.len == 0:
                wallet = newWallet(password)
            else:
                try:
                    wallet = newWallet(mnemonic, password)
                except ValueError as e:
                    fcRaise e

        #Create a Send Transaction.
        functions.personal.send = proc (
            destination: string,
            amountStr: string
        ): Hash[384] {.forceCheck: [
            ValueError,
            NotEnoughMeros
        ].} =
            var
                #Wallet we're using.
                child: HDWallet
                #Spendable UTXOs.
                utxos: seq[SendInput]
                #Amount in.
                amountIn: uint64
                #Amount out.
                amountOut: uint64
                #Send we'll end up creating.
                send: Send
            try:
                child = wallet.external.next()
            except ValueError as e:
                doAssert(false, "Wallet has no usable keys: " & e.msg)
            utxos = transactions.getUTXOs(child.publicKey)
            try:
                amountOut = parseUInt(amountStr)
            except ValueError as e:
                fcRaise e

            #Grab the needed UTXOs.
            try:
                var i: int = 0
                while i < utxos.len:
                    if transactions.loadSpenders(utxos[i]).len != 0:
                        utxos.delete(i)
                        continue

                    #Add this UTXO's amount to the amount in.
                    amountIn += transactions[utxos[i].hash].outputs[utxos[i].nonce].amount

                    #Remove uneeded UTXOs.
                    if amountIn >= amountOut:
                        if i + 1 < utxos.len:
                            utxos.delete(i + 1, utxos.len - 1)
                        break

                    #Increment i.
                    inc(i)
            except IndexError as e:
                doAssert(false, "Couldn't load a transaction we have an UTXO for: " & e.msg)

            #Make sure we have enough Meros.
            if amountIn < amountOut:
                raise newException(NotEnoughMeros, "Wallet didn't have enough money to create a Send.")

            #Create the outputs.
            var outputs: seq[SendOutput]
            try:
                outputs = @[
                    newSendOutput(
                        newEdPublicKey(cast[string](destination.getEncodedData())),
                        amountOut
                    )
                ]
            except EdPublicKeyError as e:
                raise newException(ValueError, e.msg)
            except ValueError as e:
                fcRaise e

            #Add a change output.
            if amountIn != amountOut:
                outputs.add(
                    newSendOutput(
                        child.publicKey,
                        amountIn - amountOut
                    )
                )

            #Create the Send.
            send = newSend(
                utxos,
                outputs
            )

            #Sign the Send.
            child.sign(send)

            #Mine the Send.
            send.mine(functions.consensus.getSendDifficulty())

            #Add the Send.
            try:
                functions.transactions.addSend(send)
            except ValueError as e:
                doAssert(false, "Created a Send which was invalid: " & e.msg)
            except DataExists as e:
                doAssert(false, "Created a Send which already existed: " & e.msg)

            #Retun the hash.
            result = send.hash

    #Create a Data Transaction.
    functions.personal.data = proc (
        dataStr: string
    ): Hash[384] {.forceCheck: [
        ValueError,
        DataExists
    ].} =
        var
            #Wallet we're using.
            child: HDWallet
            #Data.
            data: Data
        try:
            child = wallet.external.next()
        except ValueError as e:
            doAssert(false, "Wallet has no usable keys: " & e.msg)

        try:
            data = newData(
                transactions.loadDataTip(child.publicKey),
                dataStr
            )
        except ValueError as e:
            fcRaise e

        #Sign the Data.
        child.sign(data)

        #Mine the Data.
        data.mine(functions.consensus.getDataDifficulty())

        #Add the Data.
        try:
            functions.transactions.addData(data)
        except ValueError as e:
            doAssert(false, "Created a Data which was invalid: " & e.msg)
        except DataExists as e:
            fcRaise e

        #Retun the hash.
        result = data.hash
