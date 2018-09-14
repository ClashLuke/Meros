#Import the numerical libraries.
import BN
import ../../lib/Base

#Import the Address library.
import ../../Wallet/Address

#Common serialization functions.
import SerializeCommon

#String utils standard library.
import strutils

#Serialization function.
proc serialize*(
    miners: seq[tuple[miner: string, amount: int]],
    nonce: BN
): string {.raises: [ValueError, Exception].} =
    #Create the result.
    result = !nonce.toString(256)

    #Add each miner.
    for miner in 0 ..< miners.len:
        result &=
            !Address.toBN(miners[miner].miner).toString(256) &
            $char(1) & $char(miners[miner].amount)
