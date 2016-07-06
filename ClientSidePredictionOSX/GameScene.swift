//
//  GameScene.swift
//  ClientSidePredictionOSX
//
//  Created by Noah Hilt on 6/21/16.
//  Copyright (c) 2016 noeski. All rights reserved.
//

import SpriteKit

class Input {
    var uid = 0
    var dt = CFTimeInterval(0.0)
    var leftArrowPressed = false
    var rightArrowPressed = false
    var downArrowPressed = false
    var upArrowPressed = false
    
    func toDictionary() -> [String: AnyObject] {
        var dictionary = [String: AnyObject]()
        
        dictionary["id"] = uid
        dictionary["dt"] = dt
        dictionary["leftArrowPressed"] = leftArrowPressed
        dictionary["rightArrowPressed"] = rightArrowPressed
        dictionary["downArrowPressed"] = downArrowPressed
        dictionary["upArrowPressed"] = upArrowPressed

        return dictionary
    }
    
    class func fromDictionary(dictionary: [String: AnyObject]) -> Input {
        let input = Input()
        input.uid = dictionary["id"] as! Int
        input.dt = dictionary["dt"] as! CFTimeInterval
        input.leftArrowPressed = dictionary["leftArrowPressed"] as! Bool
        input.rightArrowPressed = dictionary["rightArrowPressed"] as! Bool
        input.downArrowPressed = dictionary["downArrowPressed"] as! Bool
        input.upArrowPressed = dictionary["upArrowPressed"] as! Bool

        return input
    }
}

class PlayerSnapshot {
    var playerID = ""
    var posX = CGFloat(0.0)
    var posY = CGFloat(0.0)
    var rot = CGFloat(0.0)
}

class WorldSnapshot {
    var lastInput = 0
    var serverTime = CFTimeInterval(0.0)
    var playerSnapshots = [PlayerSnapshot]()
    
    func toDictionary() -> [String: AnyObject] {
        var dictionary = [String: AnyObject]()
        var playersSnapshot = [AnyObject]()
        
        for player in playerSnapshots {
            var playerSnapshot = [String: AnyObject]()
            playerSnapshot["id"] = player.playerID
            playerSnapshot["posX"] = player.posX
            playerSnapshot["posY"] = player.posY
            playerSnapshot["rot"] = player.rot
            
            playersSnapshot.append(playerSnapshot)
        }
        
        dictionary["lastInput"] = lastInput
        dictionary["serverTime"] = serverTime
        dictionary["players"] = playersSnapshot

        return dictionary
    }
    
    class func fromDictionary(dictionary: [String: AnyObject]) -> WorldSnapshot {
        let snapshot = WorldSnapshot()
        snapshot.lastInput = dictionary["lastInput"] as! Int
        snapshot.serverTime = dictionary["serverTime"] as! CFTimeInterval
        
        for playerDictionary in (dictionary["players"] as! [[String: AnyObject]]) {
            let playerSnapshot = PlayerSnapshot()
            playerSnapshot.playerID = playerDictionary["id"] as! String
            playerSnapshot.posX = playerDictionary["posX"] as! CGFloat
            playerSnapshot.posY = playerDictionary["posY"] as! CGFloat
            playerSnapshot.rot = playerDictionary["rot"] as! CGFloat

            snapshot.playerSnapshots.append(playerSnapshot)
        }
        
        
        return snapshot
    }
}

class GameScene: SKScene, SocketListener {
    var status: SKLabelNode?
    var clientButton: SKButton?
    var serverButton: SKButton?
    var disconnectButton: SKButton?
    var socket: Socket?
    var clients = [Socket]()

    var player: Player?
    var players: SKNode?

    var leftArrowPressed = false
    var rightArrowPressed = false
    var downArrowPressed = false
    var upArrowPressed = false
    var tickTime = CFTimeInterval()
    var lastTime = CFTimeInterval()
    var isServer = false
    var lastZPosition = CGFloat(1.0)
    
    var lastServerSnapshotSendTime = CFTimeInterval()
    var lastClientInputSendTime = CFTimeInterval()

    var lastPingTime = CFTimeInterval()
    var lastServerTime = CFTimeInterval()
    var clientServerTime = CFTimeInterval()
    
    var nextInputID = 0
    var inputQueue = [Input]()
    var unsentInputQueue = [Input]()
    var worldSnapshots = [WorldSnapshot]()
    
    override func didMoveToView(view: SKView) {
        status = SKLabelNode()
        status?.horizontalAlignmentMode = SKLabelHorizontalAlignmentMode.Left
        status?.verticalAlignmentMode = SKLabelVerticalAlignmentMode.Bottom
        
        clientButton = SKButton(texture: nil, color: NSColor.redColor(), size: CGSizeMake(200, 44), text: "Client")
        clientButton?.action = {
            self.startClient()
        }
        
        serverButton = SKButton(texture: nil, color: NSColor.redColor(), size: CGSizeMake(200, 44), text: "Server")
        serverButton?.action = {
            self.startServer()
        }
        
        disconnectButton = SKButton(texture: nil, color: NSColor.redColor(), size: CGSizeMake(200, 44), text: "Disconnect")
        disconnectButton?.hidden = true
        disconnectButton?.action = {
            self.disconnect()
        }
        
        players = SKNode()
        
        self.addChild(players!)
        self.addChild(status!)
        self.addChild(clientButton!)
        self.addChild(serverButton!)
        self.addChild(disconnectButton!)
    
        self.didChangeSize(CGSizeZero)
    }
    
    override func update(currentTime: CFTimeInterval) {
        SocketManager.sharedManager.update()
        
        if lastTime == 0 {
            lastTime = currentTime
        }
        
        let dt = currentTime - lastTime
        tickTime += dt

        if socket != nil && player != nil {
            processInput(dt)
        
            if isServer {
                if (tickTime - lastServerSnapshotSendTime) >= 0.05 {
                    lastServerSnapshotSendTime = tickTime

                    if let snapshot = worldSnapshots.last {
                        for playerSnapshot in snapshot.playerSnapshots {
                            if playerSnapshot.playerID == player!.name {
                                continue
                            }
                            
                            if let player = players?.childNodeWithName(playerSnapshot.playerID) as? Player {
                                player.position = CGPoint(x: playerSnapshot.posX, y: playerSnapshot.posY)
                                player.zRotation = playerSnapshot.rot
                                
                                for input in player.pendingInputs {
                                    applyInput(input, player: player)
                                }
                                
                                player.pendingInputs.removeAll()
                            }
                        }
                    }
                    
                    let snapshot = generateSnapshot()
                    
                    for player in players?.children as! [Player] {
                        if let socket = player.socket {
                            snapshot.lastInput = player.lastInputID
                            
                            var snapshotDictionary = [String: AnyObject]()
                            snapshotDictionary["id"] = "snapshot"
                            snapshotDictionary["snapshot"] = snapshot.toDictionary()
                            
                            socket.send(snapshotDictionary)
                        }
                    }
                    
                    worldSnapshots.append(snapshot)
                }
            }
            else {
                if (tickTime - lastClientInputSendTime) >= 0.02 && unsentInputQueue.count > 0 {
                    lastClientInputSendTime = tickTime
                    
                    var dictionary = [String: AnyObject]()
                    dictionary["id"] = "input"
                    
                    var inputs = [[String: AnyObject]]()
                    for input in unsentInputQueue {
                        inputs.append(input.toDictionary())
                    }
                    unsentInputQueue.removeAll()
                    
                    dictionary["inputs"] = inputs
                    socket?.send(dictionary)
                }
                
                //if (tickTime - lastPingTime) >= 1.0 {
                //  ping()
                //}
            }
            
            interpolateWorld()
        }
        
        lastTime = currentTime
    }
    
    override func didChangeSize(oldSize: CGSize) {
        status?.position = CGPoint(x: 8, y: 8)
        clientButton?.position = CGPoint(x: 8 + clientButton!.size.width * 0.5, y: size.height - (8 + clientButton!.size.height * 0.5))
        serverButton?.position = CGPoint(x: 8 + serverButton!.size.width * 0.5, y: size.height - (8 + clientButton!.size.height + 8 + serverButton!.size.height * 0.5))
        disconnectButton?.position = CGPoint(x: 8 + disconnectButton!.size.width * 0.5, y: size.height - (8 + disconnectButton!.size.height * 0.5))
    }
    
    override func keyDown(theEvent: NSEvent) {
        switch theEvent.keyCode {
        case 123: //Left Arrow
            leftArrowPressed = true
        case 124: //Right Arrow
            rightArrowPressed = true
        case 125: //Down Arrow
            downArrowPressed = true
        case 126: //Up Arrow
            upArrowPressed = true
        default: break
        }
    }
    
    override func keyUp(theEvent: NSEvent) {
        switch theEvent.keyCode {
        case 123: //Left Arrow
            leftArrowPressed = false
        case 124: //Right Arrow
            rightArrowPressed = false
        case 125: //Down Arrow
            downArrowPressed = false
        case 126: //Up Arrow
            upArrowPressed = false
        default: break
        }
    }
    
    func processInput(dt: CFTimeInterval) {
        if !leftArrowPressed && !rightArrowPressed && !upArrowPressed && !downArrowPressed {
            return
        }
        
        let input = Input()
        input.dt = dt
        input.leftArrowPressed = leftArrowPressed
        input.rightArrowPressed = rightArrowPressed
        input.upArrowPressed = upArrowPressed
        input.downArrowPressed = downArrowPressed

        applyInput(input, player: player!)
        
        if !isServer {
            nextInputID += 1
            input.uid = nextInputID
            inputQueue.append(input)
            unsentInputQueue.append(input)
        }
    }
    
    func applyInput(input: Input, player: Player) {
        player.lastInputID = input.uid
        
        if input.leftArrowPressed {
            player.zRotation += CGFloat(M_PI * input.dt)
        }
        
        if input.rightArrowPressed {
            player.zRotation -= CGFloat(M_PI * input.dt)
        }
        
        if input.upArrowPressed {
            let velocity = CGFloat(80.0 * input.dt)
            let dx = velocity * cos(player.zRotation + CGFloat(M_PI_2))
            let dy = velocity * sin(player.zRotation + CGFloat(M_PI_2))
            
            player.position = CGPoint(x: player.position.x + dx, y: player.position.y + dy)
        }
        
        if input.downArrowPressed {
            let velocity = CGFloat(80.0 * input.dt)
            let dx = velocity * cos(player.zRotation + CGFloat(M_PI_2))
            let dy = velocity * sin(player.zRotation + CGFloat(M_PI_2))
            
            player.position = CGPoint(x: player.position.x - dx, y: player.position.y - dy)
        }
    }
    
    func interpolateWorld() {
        if worldSnapshots.count < 2 {
            return
        }
        
        let worldTime = tickTime - 0.1
        var idx = -1
        
        for i in (0..<worldSnapshots.count-1).reverse() {
            let snapshot = worldSnapshots[i]
            let time = serverToClientTime(snapshot.serverTime)

            if time <= worldTime {
                idx = i
                break
            }
        }
        
        if idx >= 0 {
            let previousSnapshot = worldSnapshots[idx]
            let nextSnapshot = worldSnapshots[idx+1]
            
            let startTime = serverToClientTime(previousSnapshot.serverTime)
            let endTime = serverToClientTime(nextSnapshot.serverTime)
            
            var t = CGFloat((worldTime - startTime) / (endTime - startTime)) //Linear
            t = (t*t) * (3 - 2 * t) //SmoothStep
            //t = CGFloat(-cos(M_PI * Double(t))  * 0.5) + 0.5 //Cosine
            
            for previousPlayerSnapshot in previousSnapshot.playerSnapshots {
                for nextPlayerSnapshot in nextSnapshot.playerSnapshots {
                    if previousPlayerSnapshot.playerID == nextPlayerSnapshot.playerID {
                        var player = players?.childNodeWithName(previousPlayerSnapshot.playerID)
                        
                        if player == self.player {
                            continue
                        }
                        
                        if !isServer && player == nil {
                            player = Player()
                            player?.name = previousPlayerSnapshot.playerID
                            player?.setScale(0.25)
                            
                            players?.addChild(player!)
                        }
                        
                        player?.position = CGPoint(x: (nextPlayerSnapshot.posX - previousPlayerSnapshot.posX) * t + previousPlayerSnapshot.posX, y: (nextPlayerSnapshot.posY - previousPlayerSnapshot.posY) * t + previousPlayerSnapshot.posY)
                        player?.zRotation = (nextPlayerSnapshot.rot - previousPlayerSnapshot.rot) * t + previousPlayerSnapshot.rot
                    }
                }
            }
        }
        
        let expirationTime = tickTime - 1.0
        var expIdx = -1
        
        for i in 0..<worldSnapshots.count {
            let snapshot = worldSnapshots[i]
            let time = serverToClientTime(snapshot.serverTime)
            
            if time <= expirationTime {
                expIdx = i
            }
        }
        
        if expIdx >= 0 {
            worldSnapshots.removeRange(0...expIdx)
        }
    }
    
    func processServerSnapshot(snapshot: WorldSnapshot) {
        worldSnapshots.append(snapshot)
        
        for playerSnapshot in snapshot.playerSnapshots {
            if playerSnapshot.playerID == player?.name! {
                player?.position = CGPoint(x: playerSnapshot.posX, y: playerSnapshot.posY)
                player?.zRotation = playerSnapshot.rot
                break
            }
        }
        
        while !inputQueue.isEmpty {
            let input = inputQueue.first!
            
            if input.uid <= snapshot.lastInput {
                inputQueue.removeFirst()
            }
            else {
                break
            }
        }
        
        for input in inputQueue {
            applyInput(input, player: player!)
        }
    }
    
    func generateSnapshot(reset: Bool = false) -> WorldSnapshot {
        if reset {
            if let snapshot = worldSnapshots.last {
                for playerSnapshot in snapshot.playerSnapshots {
                    if playerSnapshot.playerID == player!.name {
                        continue
                    }
                    
                    if let player = players?.childNodeWithName(playerSnapshot.playerID) {
                        player.position = CGPoint(x: playerSnapshot.posX, y: playerSnapshot.posY)
                        player.zRotation = playerSnapshot.rot
                    }
                }
            }
        }
        
        let snapshot = WorldSnapshot()
        snapshot.serverTime = tickTime
        
        for player in players!.children {
            let playerSnapshot = PlayerSnapshot()
            playerSnapshot.playerID = player.name!
            playerSnapshot.posX = player.position.x
            playerSnapshot.posY = player.position.y
            playerSnapshot.rot = player.zRotation
            snapshot.playerSnapshots.append(playerSnapshot)
        }
        
        return snapshot
    }
    
    func sendHandshake() {
        lastPingTime = tickTime
        
        var dictionary = [String: AnyObject]()
        dictionary["id"] = "handshake"
        dictionary["timestamp"] = tickTime
        
        socket?.send(dictionary)
    }
    
    func processHandshake(socket: Socket, dictionary: [String: AnyObject]) {
        var dictionary = [String: AnyObject]()
        dictionary["id"] = "init"
        dictionary["timestamp"] = tickTime
        dictionary["snapshot"] = generateSnapshot(true).toDictionary()
        
        let player = Player()
        player.name = NSUUID().UUIDString
        player.position = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        player.zPosition = lastZPosition++
        player.socket = socket
        players?.addChild(player)
        
        var playerSnapshot = [String: AnyObject]()
        playerSnapshot["id"] = player.name
        playerSnapshot["z"] = player.zPosition
        playerSnapshot["posX"] = player.position.x
        playerSnapshot["posY"] = player.position.y
        playerSnapshot["rot"] = player.zRotation
        
        dictionary["player"] = playerSnapshot
        socket.send(dictionary)
    }
    
    func processInit(dictionary: [String: AnyObject]) {
        lastServerTime = dictionary["timestamp"] as! CFTimeInterval
        clientServerTime = tickTime - (lastServerTime - ((tickTime - lastPingTime) * 0.5)) //TODO: Figure out RTT
                
        let playerDictionary = dictionary["player"] as! [String: AnyObject]
        
        player = Player()
        player?.name = playerDictionary["id"] as? String
        player?.zPosition = playerDictionary["z"] as! CGFloat
        player?.position = CGPoint(x: playerDictionary["posX"] as! CGFloat, y: playerDictionary["posY"] as! CGFloat)
        player?.zRotation = playerDictionary["rot"] as! CGFloat
        
        players?.addChild(player!)
        
        let worldSnapshot = WorldSnapshot.fromDictionary(dictionary["snapshot"] as! [String: AnyObject])
        processServerSnapshot(worldSnapshot)
    }
    
    func processClientInput(socket: Socket, dictionary: [String: AnyObject]) {
        for player in players!.children as! [Player] {
            if player.socket === socket {
                let inputs = dictionary["inputs"] as! [[String: AnyObject]]
                for inputDictionary in inputs {
                    let input = Input.fromDictionary(inputDictionary)
                    player.pendingInputs.append(input)
                }
                
                break
            }
        }
    }
    
    func ping() {
        lastPingTime = tickTime
        
        var dictionary = [String: AnyObject]()
        dictionary["id"] = "ping"
        dictionary["timestamp"] = tickTime
        
        socket?.send(dictionary)
    }
    
    func pong(socket: Socket) {
        var dictionary = [String: AnyObject]()
        dictionary["id"] = "pong"
        dictionary["timestamp"] = tickTime
        
        socket.send(dictionary)
    }
    
    func clientToServerTime(time: CFTimeInterval) -> CFTimeInterval {
        return time - clientServerTime
    }
    
    func serverToClientTime(time: CFTimeInterval) -> CFTimeInterval {
        return time + clientServerTime
    }
    
    func startServer() {
        socket = Socket()
        socket?.listener = self
        
        if !socket!.listen(3030) {
            socket = nil
            return
        }
        
        isServer = true
        status?.text = "Server Listening"
        clientButton?.hidden = true
        serverButton?.hidden = true
        
        disconnectButton?.hidden = false
        
        player = Player()
        player?.name = NSUUID().UUIDString
        player?.position = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        players?.addChild(player!)
    }
    
    func startClient() {
        let alert = NSAlert()
        alert.messageText = "Enter Server Address"
        alert.addButtonWithTitle("Connect")
        alert.addButtonWithTitle("Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = "127.0.0.1"
        
        alert.accessoryView = input
        alert.beginSheetModalForWindow(self.view!.window!) { (modalResponse) in
            if modalResponse == NSAlertFirstButtonReturn {
                self.startClient(input.stringValue)
            }
        }
    }
    
    func startClient(server: String) {
        socket = Socket()
        socket?.listener = self
        
        if !socket!.connect(server, port: 3030) {
            socket = nil
            return
        }
        
        isServer = false
        status?.text = "Connecting..."
        
        clientButton?.hidden = true
        serverButton?.hidden = true
        
        disconnectButton?.hidden = false
    }
    
    func disconnect() {
        socket?.close()
        socket = nil
    }
}

extension GameScene {
    func onSocketConnected(socket: Socket) {
        status?.text = "Connected"
        sendHandshake()
    }
    
    func onSocketClosed(socket: Socket) {
        if socket === self.socket! {
            clientButton?.hidden = false
            serverButton?.hidden = false
            
            disconnectButton?.hidden = true
            status?.text = "Disconnected"
            
            player?.removeFromParent()
            player = nil
            
            players?.removeAllChildren()
        }
        else {
            let index = (clients as NSArray).indexOfObject(socket)
            
            if index != NSNotFound {
                clients.removeAtIndex(index)
            }
            
            for player in players!.children as! [Player] {
                if player.socket === socket {
                    player.removeFromParent()
                    break
                }
            }
        }
    }
    
    func onClientConnected(socket: Socket, client: Socket) {
        client.listener = self
        clients.append(client)
    }
    
    func onSocketReceivedMessage(socket: Socket, message: [String : AnyObject]) {
        if let id = message["id"] as! String? {
            switch id {
                case "handshake":
                    processHandshake(socket, dictionary: message)
                
                case "init":
                    processInit(message)
                
                case "snapshot":
                    let worldSnapshot = WorldSnapshot.fromDictionary(message["snapshot"] as! [String: AnyObject])
                    processServerSnapshot(worldSnapshot)
                
                case "input":
                    processClientInput(socket, dictionary: message)
                
                default:
                    break
            }
        }        
    }
}
