#Types.
from typing import IO, Dict, List, Any

#Data class.
from PythonTests.Classes.Transactions.Data import Data

#Consensus classes.
from PythonTests.Classes.Consensus.Element import SignedElement
from PythonTests.Classes.Consensus.Verification import SignedVerification
from PythonTests.Classes.Consensus.MeritRemoval import SignedMeritRemoval
from PythonTests.Classes.Consensus.Consensus import Consensus

#Blockchain classes.
from PythonTests.Classes.Merit.BlockHeader import BlockHeader
from PythonTests.Classes.Merit.BlockBody import BlockBody
from PythonTests.Classes.Merit.Block import Block
from PythonTests.Classes.Merit.Blockchain import Blockchain

#BLS lib.
import blspy

#Ed25519 lib.
import ed25519

#Time standard function.
from time import time

#JSON standard lib.
import json

#Consensus.
consensus: Consensus = Consensus(
    bytes.fromhex("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
    bytes.fromhex("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"),
)
#Blockchain.
blockchain: Blockchain = Blockchain(
    b"MEROS_DEVELOPER_NETWORK",
    60,
    int("FAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 16)
)

#BLS Keys.
privKey: blspy.PrivateKey = blspy.PrivateKey.from_seed(b'\0')
pubKey: blspy.PublicKey = privKey.get_public_key()

#Ed25519 keys.
edKeys: List[ed25519.SigningKey] = []
for i in range(6):
    edKeys.append(ed25519.SigningKey(i.to_bytes(1, "big") * 32))

#Add a single Block to create Merit.
bbFile: IO[Any] = open("PythonTests/Vectors/Merit/BlankBlocks.json", "r")
blocks: List[Dict[str, Any]] = json.loads(bbFile.read())
blockchain.add(Block.fromJSON(blocks[0]))
bbFile.close()

#Create a Data per key.
datas: List[Data] = []
for edPrivKey in edKeys:
    datas.append(Data(
        edPrivKey.get_verifying_key().to_bytes().rjust(48, b'\0'),
        bytes()
    ))
    datas[-1].sign(edPrivKey)
    datas[-1].beat(consensus.dataFilter)

#Create 1 Verification per Data.
verifs: List[SignedVerification] = []
for d in range(len(datas)):
    verifs.append(SignedVerification(datas[d].hash))
    verifs[-1].sign(privKey, d)
    consensus.add(verifs[-1])

#Create a MeritRemoval off the last one.
sv: SignedVerification = SignedVerification(b'\0' * 48)
sv.sign(privKey, 5)
removal: SignedMeritRemoval = SignedMeritRemoval(
    SignedElement.fromElement(verifs[5]),
    SignedElement.fromElement(sv)
)
consensus.add(removal)

#Generate a Block with the Verifications.
block: Block = Block(
    BlockHeader(
        2,
        blockchain.last(),
        int(time()),
        consensus.getAggregate([(pubKey, 0, 5)])
    ),
    BlockBody([(pubKey, 5, consensus.getMerkle(pubKey, 0, 5))])
)
#Mine it.
block.mine(blockchain.difficulty())

#Add it.
blockchain.add(block)
print("Generated Pending Actions Block " + str(block.header.nonce) + ".")

#Generate 4 more Blocks.
for i in range(3, 7):
    block = Block(BlockHeader(i, blockchain.last(), int(time())), BlockBody())
    #Mine it.
    block.mine(blockchain.difficulty())

    #Add it.
    blockchain.add(block)
    print("Generated Pending Actions Block " + str(block.header.nonce) + ".")

#Generate a Block with the MeritRemoval.
block = Block(
    BlockHeader(
        7,
        blockchain.last(),
        int(time()),
        consensus.getAggregate([(pubKey, 6, -1)])
    ),
    BlockBody([(pubKey, 6, consensus.getMerkle(pubKey, 6))])
)
#Mine it.
block.mine(blockchain.difficulty())

#Add it.
blockchain.add(block)
print("Generated Pending Actions Block " + str(block.header.nonce) + ".")

result: Dict[str, Any] = {
    "blockchain":    blockchain.toJSON(),
    "datas":         [],
    "verifications": [],
    "removal":       removal.toSignedJSON()
}
for data in datas:
    result["datas"].append(data.toVector())
for verif in verifs:
    result["verifications"].append(verif.toSignedJSON())

vectors: IO[Any] = open("PythonTests/Vectors/Consensus/MeritRemoval/PendingActions.json", "w")
vectors.write(json.dumps(result))
vectors.close()
