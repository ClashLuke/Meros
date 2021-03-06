#Types.
from typing import Dict, List, Tuple

#Mint and Transactions classes.
from PythonTests.Classes.Transactions.Mint import Mint
from PythonTests.Classes.Transactions.Transactions import Transactions

#Verification Consensus classes.
from PythonTests.Classes.Consensus.Verification import Verification
from PythonTests.Classes.Consensus.Consensus import Consensus

#Block and State classes.
from PythonTests.Classes.Merit.Block import Block
from PythonTests.Classes.Merit.State import State

#BLS lib.
import blspy

#Epochs class.
class Epochs:
    #Constructor.
    def __init__(
        self
    ) -> None:
        self.tips: Dict[bytes, int] = {}
        self.epochs: List[Dict[bytes, List[bytes]]] = [{}, {}, {}, {}, {}]
        self.mint: int = 0

    #Turn scores into rewards.
    def reward(
        self,
        scores: List[Tuple[bytes, int]]
    ) -> List[Mint]:
        result: List[Mint] = []
        for score in scores:
            if score[1] == 0:
                continue

            result.append(Mint(
                self.mint,
                (blspy.PublicKey.from_bytes(score[0]), score[1] * 50)
            ))
            self.mint += 1
        return result

    #Score an Epoch and generate rewards.
    def score(
        self,
        transactions: Transactions,
        state: State,
        epoch: Dict[bytes, List[bytes]]
    ) -> List[Mint]:
        #Grab the verified transactions.
        verified: List[bytes] = []
        for tx in epoch:
            if transactions.txs[tx].verified:
                verified.append(tx)

        if not verified:
            return []

        #Assign each Merit Holder 1 point per verified transaction.
        scores: Dict[bytes, int] = {}
        for tx in verified:
            for holder in epoch[tx]:
                if not holder in scores:
                    scores[holder] = 0
                scores[holder] += 1

        #Multiply each Merit Holder's score by their weight.
        total: int = 0
        tupleScores: List[Tuple[bytes, int]] = []
        for holder in scores:
            score: int = scores[holder] * state.live[holder]
            total += score
            tupleScores.append((holder, score))

        #Sort the scores and remove trailing scores.
        tupleScores.sort(key=lambda tup: (tup[1], int.from_bytes(tup[0], "big")), reverse=True)
        for i in range(100, len(tupleScores)):
            del tupleScores[i]

        #Normalize each score to 1000.
        for i in range(len(tupleScores)):
            tupleScores[i] = (tupleScores[i][0], tupleScores[i][1] * 1000 // total)

        #If we don't have a perfect 1000, fix that.
        total = 0
        for tupleScore in tupleScores:
            total += tupleScore[1]
        tupleScores[0] = (tupleScores[0][0], tupleScores[0][1] + (1000 - total))

        #Create Mints.
        return self.reward(tupleScores)

    #Add block.
    def add(
        self,
        transactions: Transactions,
        consensus: Consensus,
        state: State,
        block: Block
    ) -> List[Mint]:
        #Construct the new Epoch.
        epoch: Dict[bytes, List[bytes]] = {}
        for record in block.body.records:
            mh: bytes = record[0].serialize()
            start = 0
            if mh in self.tips:
                start = self.tips[mh]
            self.tips[mh] = record[1]

            for e in range(start, record[1] + 1):
                if isinstance(consensus.holders[mh][e], Verification):
                    tx: bytes = Verification.fromElement(consensus.holders[mh][e]).hash
                    if not tx in epoch:
                        epoch[tx] = []
                    epoch[tx].append(mh)

        #Move TXs belonging to an old Epoch to said Epoch.
        txs: List[bytes] = list(epoch.keys())
        for tx in txs:
            for e in range(5):
                if tx in self.epochs[e]:
                    self.epochs[e][tx] += epoch[tx]
                    del epoch[tx]

        #Grab the oldest Epoch.
        self.epochs.append(epoch)
        epoch = self.epochs[0]
        del self.epochs[0]

        return self.score(transactions, state, epoch)
