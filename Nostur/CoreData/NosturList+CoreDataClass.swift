//
//  NosturList+CoreDataClass.swift
//  Nostur
//
//  Created by Fabian Lachman on 15/04/2023.
//
//

import Foundation
import CoreData

public class NosturList: NSManagedObject {

    static func generateExamples(context: NSManagedObjectContext) {
        let contacts = PreviewFetcher.allContacts(context: context)
        for i in 0..<10 {
            let list = NosturList(context: context)
            list.name = "Example List \(i)"
            list.addToContacts(NSSet(array: contacts.randomSample(count: 10)))
        }
    }
    
    static func fetchLists(context:NSManagedObjectContext) -> [NosturList] {
        let request = NSFetchRequest<NosturList>(entityName: "NosturList")
        return (try? context.fetch(request)) ?? []
    }
}
