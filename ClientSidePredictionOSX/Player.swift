//
//  Player.swift
//  ClientSidePrediction
//
//  Created by Noah Hilt on 6/24/16.
//  Copyright © 2016 noeski. All rights reserved.
//

import SpriteKit

class Player : SKSpriteNode {
    var lastInputID = 0
    var socket: Socket?
    var pendingInputs = [Input]()
    
    init() {
        let texture = SKTexture(imageNamed: "Spaceship")
        super.init(texture: texture, color: NSColor.clearColor(), size: texture.size())
        self.setScale(0.25)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}