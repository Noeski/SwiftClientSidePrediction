//
//  SKButton.swift
//  ClientSidePrediction
//
//  Created by Noah Hilt on 6/21/16.
//  Copyright © 2016 noeski. All rights reserved.
//

import SpriteKit
import Foundation

class SKButton : SKSpriteNode {
    var label: SKLabelNode
    var action: (() -> Void)?
    
    init(texture: SKTexture?, color: NSColor, size: CGSize, text: String) {
        label = SKLabelNode(text: text)
        label.verticalAlignmentMode = SKLabelVerticalAlignmentMode.Center

        super.init(texture: texture, color: color, size: size)
        
        userInteractionEnabled = true
        addChild(label)
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func mouseDown(theEvent: NSEvent) {
       self.runAction(SKAction.scaleBy(0.8, duration: 0.1))
    }
    
    override func mouseDragged(theEvent: NSEvent) {
        let location: CGPoint = theEvent.locationInNode(self.parent!)
        
        if self.containsPoint(location) {

        } else {

        }
    }
   
    override func mouseUp(theEvent: NSEvent) {
        self.runAction(SKAction.scaleBy(1.25, duration: 0.1))

        let location: CGPoint = theEvent.locationInNode(self.parent!)

        if self.containsPoint(location) {
            action?()
        }
    }
}
