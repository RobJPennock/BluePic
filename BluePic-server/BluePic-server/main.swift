//
//  main.swift
//  BluePic-server
//
//  Created by Ira Rosen on 28/12/15.
//  Copyright © 2015 IBM. All rights reserved.
//

import router
import sys
import net

import SwiftCouchDB

import SwiftyJSON

import Foundation

let configuration = getCouchDBConfiguration()
guard  configuration != nil  else {
    print("Failed to read the configuration file!")
    exit(1)
}


let server = CouchDBServer(ipAddress: configuration!["ipAddress"] as! String,
                           port: Int16(configuration!["port"]!.integerValue))
let dbName = configuration!["db"] as! String

let database = server.db(dbName)

let router = Router()

router.get("/connect") { (request: RouterRequest, response: RouterResponse, next: ()->Void) in
    do {
        try response.status(HttpStatusCode.OK).end()
    }
    catch {
        response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
    }
    
    next()
}

router.post("/admin/setup") { (request: RouterRequest, response: RouterResponse, next: ()->Void) in
    server.dbExists(dbName) { (exists, error) in
        guard  error == nil  else {
            print(error!)
            response.error = error!
            next()
            return
        }
            
        if exists == true {
            do {
                try response.status(HttpStatusCode.OK).end()
            }
            catch {
                response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
            }

            next()
        }
        else {
            server.createDB(dbName) { (db, error) in
                guard  error == nil  else {
                    response.error = error!
                    next()
                    return
                }
                    
                if let db = db {
                    let (designName, design) = getDesign()
                    if let design = design, let designName = designName {
                        database.createDesign (designName, document: design) { (document, error) in
                            guard  error == nil  else {
                                response.error = error!
                                next()
                                return
                            }
                                
                            if let document = document {
                                do {
                                    try response.status(HttpStatusCode.OK).end()
                                }
                                catch {
                                    response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                                    }
                                }
                            else {
                                response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                            }
                            next()
                        }
                    }
                    else {
                        next()
                    }
                }
                else {
                    response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                    next()
                }
            }
        }
    }
}

    
    
router.use("/photos/*", middleware: BodyParser())


router.get("/photos") { (request: RouterRequest, response: RouterResponse, next: ()->Void) in
    database.queryByView("sortedByDate", ofDesign: "photos", usingParameters: [.Descending(true)]) { (document, error) in
        guard  error == nil  else {
            response.error = error!
            next()
            return
        }
            
        if let document = document {
            do {
                try response.status(HttpStatusCode.OK).sendJson(parsePhotosList(document)).end()
            }
            catch {
                response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
            }
        }
        else {
            response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"View not found"])
        }
        next()
    }
}


router.get("/photos/:docid/:photoid") { (request: RouterRequest, response: RouterResponse, next: ()->Void) in
    let docId = request.params["docid"]
    let attachmentName = request.params["photoid"]
    if docId != nil && attachmentName != nil {
        database.retrieveAttachment(docId!, attachmentName: attachmentName!) { (photo, error, contentType) in
            guard  error == nil  else {
                response.error = error!
                next()
                return
            }
                
            if let photo = photo {
                if let contentType = contentType {
                    response.setHeader("Content-Type", value: contentType)
                }
                do {
                    try response.status(HttpStatusCode.OK).end(photo)
                }
                catch {
                    response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                }
            }
            else {
                response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Photo not found"])
            }
            next()
        }
    }
    else {
        response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Photo not found"])
        next()
    }
}


router.post("/photos/:ownerId/:ownerName/:title/:photoname") { (request: RouterRequest, response: RouterResponse, next: ()->Void) in
    let ownerId = request.params["ownerId"]
    let ownerName = request.params["ownerName"]
    let title = request.params["title"]
    let photoName = request.params["photoname"]
    let (document, contentType) = createPhotoDocument(ownerId, ownerName: ownerName, title: title, photoName: photoName)
    var image: NSData?
        
    do {
        try image = BodyParser.readBodyData(request)
    }
    catch {
        response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Invalid photo"])
        next()
        return
    }
        
    if let document = document, let contentType = contentType {
        database.create(JSON(document)) { (id, revision, doc, error) in
            guard  error == nil  else {
                response.error = error!
                next()
                return
            }
                
            if let doc = doc, let id = id, let revision = revision {
                database.createAttachment(id, docRevison: revision, attachmentName: photoName!, attachmentData: image!, contentType: contentType) { (rev, photoDoc, error) in
                    guard  error == nil  else {
                        response.error = error!
                        next()
                        return
                    }
                    if let photoDoc = photoDoc {
                        do {
                            let reply = createUploadReply(fromDocument: document, id: id, photoName: photoName!)
                            try response.status(HttpStatusCode.OK).sendJson(reply).end()
                        }
                        catch {
                            response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                        }
                    }
                    else {
                        response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                    }
                    next()
                }
            }
            else {
                response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Internal error"])
                next()
            }            
        }
    }
    else {
        response.error = NSError(domain: "SwiftBluePic", code: 1, userInfo: [NSLocalizedDescriptionKey:"Invalid photo"])
        next()
    }
}


router.listen(8090)

Server.run()






