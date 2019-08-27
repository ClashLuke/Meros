#Tests proper handling of a MeritRemoval when Meros syncs a MeritRemoval of Elements sharing a nonce.

#Types.
from typing import Dict, IO, Any

#SignedMeritRemoval class.
from PythonTests.Classes.Consensus.MeritRemoval import SignedMeritRemoval

#Blockchain class.
from PythonTests.Classes.Merit.Blockchain import Blockchain

#TestError Exception.
from PythonTests.Tests.Errors import TestError

#Meros classes.
from PythonTests.Meros.Meros import MessageType
from PythonTests.Meros.RPC import RPC

#Merit and Consensus verifiers.
from PythonTests.Tests.Merit.Verify import verifyBlockchain
from PythonTests.Tests.Consensus.Verify import verifyMeritRemoval

#JSON standard lib.
import json

def MRSNSyncTest(
    rpc: RPC
) -> None:
    file: IO[Any] = open("PythonTests/Vectors/Consensus/MeritRemoval/SameNonce.json", "r")
    vectors: Dict[str, Any] = json.loads(file.read())
    #MeritRemoval..
    removal: SignedMeritRemoval = SignedMeritRemoval.fromJSON(vectors["removal"])
    #Blockchain.
    blockchain: Blockchain = Blockchain.fromJSON(
        b"MEROS_DEVELOPER_NETWORK",
        60,
        int("FAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 16),
        vectors["blockchain"]
    )
    file.close()

    #Handshake with the node.
    rpc.meros.connect(254, 254, len(blockchain.blocks))

    sentLast: bool = False
    reqHash: bytes = bytes()
    while True:
        msg: bytes = rpc.meros.recv()

        if MessageType(msg[0]) == MessageType.Syncing:
            rpc.meros.acknowledgeSyncing()

        elif MessageType(msg[0]) == MessageType.GetBlockHash:
            height: int = int.from_bytes(msg[1 : 5], "big")
            if height == 0:
                rpc.meros.blockHash(blockchain.last())
            else:
                if height >= len(blockchain.blocks):
                    raise TestError("Meros asked for a Block Hash we do not have.")

                rpc.meros.blockHash(blockchain.blocks[height].header.hash)

        elif MessageType(msg[0]) == MessageType.BlockHeaderRequest:
            reqHash = msg[1 : 49]
            for block in blockchain.blocks:
                if block.header.hash == reqHash:
                    rpc.meros.blockHeader(block.header)
                    break

                if block.header.hash == blockchain.last():
                    raise TestError("Meros asked for a Block Header we do not have.")

        elif MessageType(msg[0]) == MessageType.BlockBodyRequest:
            reqHash = msg[1 : 49]
            for block in blockchain.blocks:
                if block.header.hash == reqHash:
                    rpc.meros.blockBody(block.body)
                    break

                if block.header.hash == blockchain.last():
                    raise TestError("Meros asked for a Block Body we do not have.")

        elif MessageType(msg[0]) == MessageType.ElementRequest:
            sentLast = True
            rpc.meros.element(removal)

        elif MessageType(msg[0]) == MessageType.SyncingOver:
            if sentLast:
                break

        else:
            raise TestError("Unexpected message sent: " + msg.hex().upper())

    #Verify the Blockchain.
    verifyBlockchain(rpc, blockchain)

    #Verify the MeritRemoval again.
    verifyMeritRemoval(rpc, 1, 100, removal, False)

    #Playback their messages.
    rpc.meros.playback()