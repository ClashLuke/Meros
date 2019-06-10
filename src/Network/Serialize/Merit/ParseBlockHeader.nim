#Errors lib.
import ../../../lib/Errors

#Util lib.
import ../../../lib/Util

#Hash lib.
import ../../../lib/Hash

#MinerWallet lib.
import ../../../Wallet/MinerWallet

#BlockHeader object.
import ../../../Database/Merit/objects/BlockHeaderObj

#Common serialization functions.
import ../SerializeCommon
export BLOCK_HEADER_LEN

#Parse function.
proc parseBlockHeader*(
    headerStr: string
): BlockHeader {.forceCheck: [
    ValueError,
    ArgonError,
    BLSError
].} =
    if headerStr.len != BLOCK_HEADER_LEN:
        raise newException(ValueError, "parseBlockHeader handed too much data.")

    #Nonce | Last Hash | Elements Aggregate Signature | Miners Merkle | Time | Proof
    var headerSeq: seq[string] = headerStr.deserialize(
        INT_LEN,
        HASH_LEN,
        BLS_SIGNATURE_LEN,
        HASH_LEN,
        INT_LEN,
        INT_LEN
    )

    #Create the BlockHeader.
    try:
        result = newBlockHeaderObj(
            headerSeq[0].fromBinary(),
            headerSeq[1].toArgonHash(),
            newBLSSignature(headerSeq[2]),
            headerSeq[3].toBlake384Hash(),
            headerSeq[4].fromBinary(),
            headerSeq[5].fromBinary()
        )
        result.hash = Argon(headerStr.substr(0, headerStr.len - 5), headerSeq[5])
    except ValueError as e:
        fcRaise e
    except ArgonError as e:
        fcRaise e
    except BLSError as e:
        fcRaise e
