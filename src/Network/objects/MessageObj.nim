#Lattice lib.
import ../../Database/Lattice/Lattice

#Serialization common lib.
import ../Serialize/SerializeCommon

#finals lib.
import finals

finalsd:
    type
        #Message Type enum. Even though pure is no longer enforced, it does solve ambiguity issues.
        MessageType* {.pure.} = enum
            Handshake = 0,

            Syncing = 1,
            BlockRequest = 2,
            VerificationRequest = 3,
            EntryRequest = 4,
            DataMissing = 5,
            SyncingOver = 6,

            Claim = 7,
            Send = 8,
            Receive = 9,
            Data = 10,
            MemoryVerification = 11,
            Block = 12,
            Verification = 13

        #Message object.
        Message* = ref object of RootObj
            client* {.final.}: uint
            content* {.final.}: MessageType
            len* {.final.}: uint
            header* {.final.}: string
            message* {.final.}: string

#syncEntry response. Stops a segfault that occurs when we cast things around.
#This its own type as finals can't handle a type with a case statement.
type SyncEntryResponse* = ref object of RootObj
    case entry*: EntryType:
        of EntryType.Claim:
            claim*: Claim
        of EntryType.Send:
            send*: Send
        of EntryType.Receive:
            receive*: Receive
        of EntryType.Data:
            data*: Data
        else:
            discard

#Finalize the Message.
func finalize(
    msg: Message
) {.raises: [].} =
    msg.ffinalizeClient()
    msg.ffinalizeContent()
    msg.ffinalizeLen()
    msg.ffinalizeHeader()
    msg.ffinalizeMessage()

#Constructor for incoming data.
func newMessage*(
    client: uint,
    content: MessageType,
    len: uint,
    header: string,
    message: string
): Message {.raises: [].} =
    result = Message(
        client: client,
        content: content,
        len: len,
        header: header,
        message: message
    )
    result.finalize()

#Constructor for outgoing data.
func newMessage*(
    content: MessageType,
    message: string = ""
): Message {.raises: [].} =
    #Create the Message.
    result = Message(
        client: 0,
        content: content,
        len: uint(message.len),
        header: char(content) & message.lenPrefix,
        message: message
    )
    result.finalize()

#Stringify.
func `$`*(msg: Message): string {.raises: [].} =
    msg.header & msg.message
