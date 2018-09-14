#Util lib.
import ../../lib/Util

#Numerical libs.
import BN
import ../../lib/Base

#Wallet libraries.
import ../../Wallet/Address
import ../../Wallet/Wallet

#Hash lib.
import ../../lib/Hash

#Node object and Receive object.
import ../../Database/Lattice/objects/NodeObj
import ../../Database/Lattice/objects/ReceiveObj

#delim character/serialize function.
import SerializeCommon
import SerializeReceive

#SetOnce lib.
import SetOnce

#String utils standard lib.
import strutils

#Parse a Receive.
proc parseReceive*(recvStr: string): Receive {.raises: [ValueError, Exception].} =
    var
        #Public Key | Nonce | Input Address | Input Nonce | Signature
        recvSeq: seq[string] = recvStr.deserialize(5)
        #Get the sender's Public Key.
        sender: PublicKey = newPublicKey(recvSeq[0].toHex())
        #Get the nonce.
        nonce: BN = recvSeq[1].toBN(256)
        #Get the input Address.
        inputAddress: string = newAddress(recvSeq[2].toHex)
        #Get the input nonce.
        inputNonce: BN = recvSeq[3].toBN(256)
        #Get the signature.
        signature: string = recvSeq[4].toHex().pad(128)

    #Create the Receive.
    result = newReceiveObj(
        inputAddress,
        inputNonce
    )

    #Set the sender.
    result.sender.value = sender.newAddress()
    #Set the nonce.
    result.nonce.value = nonce
    #Set the hash.
    result.hash.value = SHA512(result.serialize())

    #Verify the signature.
    if not sender.verify($result.hash.toValue(), signature):
        raise newException(ValueError, "Received signature was invalid.")
    #Set the signature.
    result.signature.value = signature
