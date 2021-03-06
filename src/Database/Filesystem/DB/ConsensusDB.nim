#Errors lib.
import ../../../lib/Errors

#Util lib.
import ../../../lib/Util

#Hash lib.
import ../../../lib/Hash

#MinerWallet lib.
import ../../../Wallet/MinerWallet

#Element lib and TransactionStatus object.
import ../../Consensus/Element
import ../../Consensus/objects/TransactionStatusObj

#Serialize/parse libs.
import Serialize/Consensus/DBSerializeElement
import Serialize/Consensus/SerializeTransactionStatus
import Serialize/Consensus/DBParseElement
import Serialize/Consensus/ParseTransactionStatus

#DB object.
import objects/DBObj
export DBObj

#Tables standard lib.
import tables

#Put/Get/Delete/Commit for the Consensus DB.
proc put(
    db: DB,
    key: string,
    val: string
) {.forceCheck: [].} =
    db.consensus.cache[key] = val

proc get(
    db: DB,
    key: string
): string {.forceCheck: [
    DBReadError
].} =
    if db.consensus.cache.hasKey(key):
        try:
            return db.consensus.cache[key]
        except KeyError as e:
            doAssert(false, "Couldn't get a key from a table confirmed to exist: " & e.msg)

    try:
        result = db.lmdb.get("consensus", key)
    except Exception as e:
        raise newException(DBReadError, e.msg)

proc delete(
    db: DB,
    key: string
) {.forceCheck: [].} =
    db.consensus.cache.del(key)
    db.consensus.deleted.add(key)

proc commit*(
    db: DB
) {.forceCheck: [].} =
    for key in db.consensus.deleted:
        try:
            db.lmdb.delete("consensus", key)
        except Exception:
            #If we delete something before it's committed, it'll throw.
            discard
    db.consensus.deleted = @[]

    var items: seq[tuple[key: string, value: string]] = newSeq[tuple[key: string, value: string]](db.consensus.cache.len + 1)
    try:
        var i: int = 0
        for key in db.consensus.cache.keys():
            items[i] = (key: key, value: db.consensus.cache[key])
            inc(i)
    except KeyError as e:
        doAssert(false, "Couldn't get a value from the table despiting getting the key from .keys(): " & e.msg)

    #Save the unmentioned hashes.
    items[^1] = (key: "unmentioned", value: db.consensus.unmentioned)
    db.consensus.unmentioned = ""

    try:
        db.lmdb.put("consensus", items)
    except Exception as e:
        doAssert(false, "Couldn't save data to the Database: " & e.msg)

    db.consensus.cache = initTable[string, string]()

#Save functions.
proc save*(
    db: DB,
    holder: BLSPublicKey,
    archived: int
) {.forceCheck: [].} =
    var holderStr: string = holder.toString()

    try:
        discard db.consensus.holders[holderStr]
    except KeyError:
        db.consensus.holders[holderStr] = true
        db.consensus.holdersStr &= holderStr
        db.put("holders", db.consensus.holdersStr)

    db.put(holderStr, $archived)

proc saveOutOfEpochs*(
    db: DB,
    holder: BLSPublicKey,
    epoch: int
) {.forceCheck: [].} =
    db.put(holder.toString() & "epoch", epoch.toBinary())

proc save*(
    db: DB,
    elem: Element
) {.forceCheck: [].} =
    db.put(elem.holder.toString() & elem.nonce.toBinary().pad(1), elem.serialize())

proc save*(
    db: DB,
    hash: Hash[384],
    status: TransactionStatus
) {.forceCheck: [].} =
    db.put(hash.toString(), status.serialize())

proc addUnmentioned*(
    db: DB,
    unmentioned: Hash[384]
) {.forceCheck: [].} =
    db.consensus.unmentioned &= unmentioned.toString()

proc loadHolders*(
    db: DB
): seq[BLSPublicKey] {.forceCheck: [].} =
    try:
        db.consensus.holdersStr = db.get("holders")
    except DBReadError:
        return @[]

    result = newSeq[BLSPublicKey](db.consensus.holdersStr.len div 48)
    for i in countup(0, db.consensus.holdersStr.len - 1, 48):
        try:
            result[i div 48] = newBLSPublicKey(db.consensus.holdersStr[i ..< i + 48])
        except BLSError as e:
            doAssert(false, "Couldn't load a holder's BLS Public Key: " & e.msg)
        db.consensus.holders[db.consensus.holdersStr[i ..< i + 48]] = true

proc load*(
    db: DB,
    holder: BLSPublicKey
): int {.forceCheck: [
    DBReadError
].} =
    try:
        result = parseInt(db.get(holder.toString()))
    except Exception as e:
        raise newException(DBReadError, e.msg)

proc loadOutOfEpochs*(
    db: DB,
    holder: BLSPublicKey
): int {.forceCheck: [].} =
    try:
        result = db.get(holder.toString() & "epoch").fromBinary()
    except Exception:
        return -1

proc load*(
    db: DB,
    holder: BLSPublicKey,
    nonce: int
): Element {.forceCheck: [
    DBReadError
].} =
    try:
        result = db.get(holder.toString() & nonce.toBinary().pad(1)).parseElement(holder, nonce)
    except Exception as e:
        raise newException(DBReadError, e.msg)

    if result of MeritRemoval:
        try:
            result.nonce = nonce
        except FinalAttributeError as e:
            doAssert(false, "Set a final attribute twice when loading a MeritRemoval: " & e.msg)

proc load*(
    db: DB,
    hash: Hash[384]
): TransactionStatus {.forceCheck: [
    DBReadError
].} =
    try:
        result = db.get(hash.toString()).parseTransactionStatus()
    except DBReadError as e:
        fcRaise e
    except ValueError, BLSError:
        doAssert(false, "Saved an invalid TransactionStatus to the DB.")

proc loadUnmentioned*(
    db: DB
): seq[Hash[384]] {.forceCheck: [].} =
    var unmentioned: string
    try:
        unmentioned = db.get("unmentioned")
    except DBReadError:
        return @[]

    result = newSeq[Hash[384]](unmentioned.len div 48)
    for i in countup(0, unmentioned.len - 1, 48):
        try:
            result[i div 48] = unmentioned[i ..< i + 48].toHash(384)
        except ValueError as e:
            doAssert(false, "Couldn't parse an unmentioned hash: " & e.msg)

#Delete an element.
proc del*(
    db: DB,
    key: BLSPublicKey,
    nonce: int
) {.forceCheck: [].} =
    db.delete(key.toString() & nonce.toBinary().pad(1))
