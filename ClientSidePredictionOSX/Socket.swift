//
//  Socket.swift
//  ClientSidePrediction
//
//  Created by Noah Hilt on 6/20/16.
//  Copyright © 2016 noeski. All rights reserved.
//

import Foundation

protocol SocketListener : class {
    func onSocketConnected(socket: Socket)
    func onSocketClosed(socket: Socket)
    func onClientConnected(socket: Socket, client: Socket)
    func onSocketReceivedMessage(socket: Socket, message: [String: AnyObject])
}

struct SocketFlags : OptionSetType {
    var rawValue: Int
    
    static let None = SocketFlags(rawValue: 0)
    static let Connecting = SocketFlags(rawValue: 1)
    static let Connected = SocketFlags(rawValue: 2)
    static let Listening = SocketFlags(rawValue: 4)
    static let CheckRead = SocketFlags(rawValue: 8)
    static let CheckWrite = SocketFlags(rawValue: 16)
    static let WriteReady = SocketFlags(rawValue: 32)
    static let Error = SocketFlags(rawValue: 64)
}

class Socket {
    weak var listener: SocketListener?
    var flags = SocketFlags.None
    var socketDescriptor: Int32 = -1
    var writeBuffer = NSMutableData()
    var readBuffer = NSMutableData()
    var readPacketSize = Int(0)
    var hasReadPacketSize = false
    
    init() {
        
    }
    
    init(descriptor: Int32) {
        initSocket(descriptor)
        
        if isValid() {
            flags = SocketFlags(rawValue: SocketFlags.Connected.rawValue | SocketFlags.CheckRead.rawValue | SocketFlags.CheckWrite.rawValue)
            SocketManager.sharedManager.addSocket(self)
        }
    }
    
    deinit {
        close()
    }
    
    func isValid() -> Bool {
        return socketDescriptor != -1
    }
    
    func connect(address: String, port: Int) -> Bool {
        initSocket()
        
        if !isValid() {
            return false
        }
        
        var sockAddr = sockaddr_in()
        sockAddr.sin_family = sa_family_t(AF_INET)
        sockAddr.sin_port = htons(in_port_t(port))
        sockAddr.sin_addr.s_addr = inet_addr(address)
        
        return withUnsafePointer(&sockAddr, {
            if Darwin.connect(socketDescriptor, UnsafePointer($0), socklen_t(sizeof(sockaddr_in))) == -1 {
                if isBlockingError(errno) {
                    flags = SocketFlags.Connecting
                    SocketManager.sharedManager.addSocket(self)
                    return true
                }
                else {
                    close()
                    return false
                }
            }
            else {
                onConnect()
                SocketManager.sharedManager.addSocket(self)
                return true
            }
        })
    }
    
    func onConnect() {
        flags = SocketFlags(rawValue: SocketFlags.Connected.rawValue | SocketFlags.CheckRead.rawValue | SocketFlags.CheckWrite.rawValue)
        listener?.onSocketConnected(self)
    }
    
    func listen(port: Int) -> Bool {
        initSocket()
        
        if !isValid() {
            return false
        }
        
        var sockAddr = sockaddr_in()
        sockAddr.sin_family = sa_family_t(AF_INET)
        sockAddr.sin_port = htons(in_port_t(port))
        sockAddr.sin_addr.s_addr = htonl(UInt32(0))
        
        return withUnsafePointer(&sockAddr, {
            if Darwin.bind(socketDescriptor, UnsafePointer($0), socklen_t(sizeof(sockaddr_in))) == -1 {
                close()
                return false
            }
            
            if Darwin.listen(socketDescriptor, 0) == -1 {
                close()
                return false
            }
            
            updateLocalAddress()
            flags = SocketFlags.Listening
            SocketManager.sharedManager.addSocket(self)
            return true
        })
    }
    
    func close() {
        if isValid() {
            Darwin.close(socketDescriptor)
            socketDescriptor = -1
            
            listener?.onSocketClosed(self)
            SocketManager.sharedManager.removeSocket(self)
        }
        
        flags = SocketFlags.None
        writeBuffer = NSMutableData()
        readBuffer = NSMutableData()
    }
    
    func accept() -> Bool {
        let clientSocketDescriptor = Darwin.accept(socketDescriptor, nil, nil)
        
        if clientSocketDescriptor == -1 {
            return false
        }
        
        let client = Socket(descriptor: clientSocketDescriptor)
        listener?.onClientConnected(self, client: client)
        
        return true
    }
    
    func tryReceive() -> Int {
        let data = NSMutableData(length: 16 * 1024)!
        let received = Darwin.recv(socketDescriptor, UnsafeMutablePointer(data.bytes), 16 * 1024, 0)
        
        if received == 0 || (received == -1 && !isBlockingError(errno)) {
            close()
        }
        else {
            readBuffer.appendBytes(data.bytes, length: received)
            
            while readBuffer.length > 0 {
                if !hasReadPacketSize {
                    if readBuffer.length >= sizeof(Int) {
                        hasReadPacketSize = true
                        readPacketSize = UnsafePointer<Int>(readBuffer.bytes).memory
                        
                        readBuffer.replaceBytesInRange(NSMakeRange(0, sizeof(Int)), withBytes: nil, length: 0)
                    }
                    else {
                        break
                    }
                }
                
                
                if hasReadPacketSize {
                    if readBuffer.length >= readPacketSize {
                        hasReadPacketSize = false
                        
                        let subData = readBuffer.subdataWithRange(NSMakeRange(0, readPacketSize))
                        readBuffer.replaceBytesInRange(NSMakeRange(0, readPacketSize), withBytes: nil, length: 0)
                        
                        do {
                            let dictionary = try NSJSONSerialization.JSONObjectWithData(subData, options: NSJSONReadingOptions()) as! [String: AnyObject]
                            listener?.onSocketReceivedMessage(self, message: dictionary)
                        }
                        catch {
                            
                        }
                    }
                    else {
                        break
                    }
                }
            }
        }
        
        return received
    }
    
    func send(dictionary: [String: AnyObject]) -> Int {
        if !isValid() {
            return 0
        }
        
        let data: NSData?
        
        do {
            data = try NSJSONSerialization.dataWithJSONObject(dictionary, options: NSJSONWritingOptions())
        }
        catch {
            return 0
        }
        
        var size = Int(data!.length)
        
        writeBuffer.appendBytes(&size, length: sizeof(Int))
        writeBuffer.appendData(data!)
        
        return trySend()
    }
    
    func trySend(writeReady: Bool = false) -> Int {
        var sent = 0
        
        if writeReady {
            flags.rawValue |= SocketFlags.WriteReady.rawValue
        }
        
        if writeBuffer.length > 0 {
            if flags.rawValue & SocketFlags.WriteReady.rawValue != 0 {
                flags.rawValue &= ~SocketFlags.WriteReady.rawValue

                sent = Darwin.send(socketDescriptor, writeBuffer.bytes, writeBuffer.length, 0)

                if sent == -1 {
                    if !isBlockingError(errno) {
                        close()
                    }
                }
                else {
                    writeBuffer.replaceBytesInRange(NSMakeRange(0, sent), withBytes: nil, length: 0)
                    
                    if writeBuffer.length > 0 {
                        flags.rawValue |= SocketFlags.CheckWrite.rawValue
                    }
                }
            }
            else {
                flags.rawValue |= SocketFlags.CheckWrite.rawValue
            }
        }
        else {
            flags.rawValue &= ~SocketFlags.CheckWrite.rawValue
        }
        
        return sent
    }
    
    private func initSocket(descriptor: Int32 = -1) {
        if isValid() {
            close()
        }
        
        socketDescriptor = descriptor == -1 ? Darwin.socket(PF_INET, SOCK_STREAM, IPPROTO_TCP) : descriptor
        
        if isValid() {
            var on = Int32(1)
            
            Darwin.setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(sizeof(Int32)))
            Darwin.setsockopt(socketDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(sizeof(Int32)))
            Darwin.setsockopt(socketDescriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(sizeof(Int32)))
            
            let flags = Darwin.fcntl(socketDescriptor, F_GETFL)
            Darwin.fcntl(socketDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
    }
    
    private func updateLocalAddress() -> Bool {
        var sockAddr = sockaddr_in()
        var sockAddrLength = socklen_t(sizeof(sockaddr_in))
        
        return withUnsafePointer(&sockAddr, {
            if Darwin.getsockname(socketDescriptor, UnsafeMutablePointer($0), &sockAddrLength) == 0 {
                return true
            }
            else {
                return false
            }
        })
    }
    
    private func htons(value: UInt16) -> UInt16 {
        return CFSwapInt16(value)
    }
    
    private func htonl(value: UInt32) -> UInt32 {
        return CFSwapInt32(value)
    }
    
    private func isBlockingError(err: Int32) -> Bool {
        return errno == EWOULDBLOCK || errno == EAGAIN || errno == EINPROGRESS;
    }
}