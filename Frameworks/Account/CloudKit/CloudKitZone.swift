//
//  CloudKitZone.swift
//  Account
//
//  Created by Maurice Parker on 3/21/20.
//  Copyright © 2020 Ranchero Software, LLC. All rights reserved.
//

import CloudKit
import os.log
import RSWeb

enum CloudKitZoneError: Error {
	case userDeletedZone
	case invalidParameter
	case unknown
}

protocol CloudKitZoneDelegate: class {
	func cloudKitDidChange(record: CKRecord);
	func cloudKitDidDelete(recordType: CKRecord.RecordType, recordID: CKRecord.ID)
}

protocol CloudKitZone: class {
	
	static var zoneID: CKRecordZone.ID { get }

	var log: OSLog { get }

	var container: CKContainer? { get }
	var database: CKDatabase? { get }
	var refreshProgress: DownloadProgress? { get set }
	var delegate: CloudKitZoneDelegate? { get set }

}

extension CloudKitZone {
	
	func resetChangeToken() {
		changeToken = nil
	}
	
	func generateRecordID() -> CKRecord.ID {
		return CKRecord.ID(recordName: UUID().uuidString, zoneID: Self.zoneID)
	}

	func resumeLongLivedOperationIfPossible() {
		guard let container = container else { return }
		container.fetchAllLongLivedOperationIDs { (opIDs, error) in
			guard let opIDs = opIDs else { return }
			for opID in opIDs {
				container.fetchLongLivedOperation(withID: opID, completionHandler: { (ope, error) in
					if let modifyOp = ope as? CKModifyRecordsOperation {
						container.add(modifyOp)
					}
				})
			}
		}
	}
	
	//    func startObservingRemoteChanges() {
	//        NotificationCenter.default.addObserver(forName: Notifications.cloudKitDataDidChangeRemotely.name, object: nil, queue: nil, using: { [weak self](_) in
	//            guard let self = self else { return }
	//            DispatchQueue.global(qos: .utility).async {
	//                self.fetchChangesInDatabase(nil)
	//            }
	//        })
	//    }
	
	func save(record: CKRecord, completion: @escaping (Result<Void, Error>) -> Void) {
		modify(recordsToSave: [record], recordIDsToDelete: [], completion: completion)
	}
	
	func delete(externalID: String, completion: @escaping (Result<Void, Error>) -> Void) {
		let recordID = CKRecord.ID(recordName: externalID, zoneID: Self.zoneID)
		modify(recordsToSave: [], recordIDsToDelete: [recordID], completion: completion)
	}

	func modify(recordsToSave: [CKRecord], recordIDsToDelete: [CKRecord.ID], completion: @escaping (Result<Void, Error>) -> Void) {
		let op = CKModifyRecordsOperation(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete)
		
		let config = CKOperation.Configuration()
		config.isLongLived = true
		op.configuration = config
		
		// We use .changedKeys savePolicy to do unlocked changes here cause my app is contentious and off-line first
		// Apple suggests using .ifServerRecordUnchanged save policy
		// For more, see Advanced CloudKit(https://developer.apple.com/videos/play/wwdc2014/231/)
		op.savePolicy = .changedKeys
		
		// To avoid CKError.partialFailure, make the operation atomic (if one record fails to get modified, they all fail)
		// If you want to handle partial failures, set .isAtomic to false and implement CKOperationResultType .fail(reason: .partialFailure) where appropriate
		op.isAtomic = true
		
		op.modifyRecordsCompletionBlock = { [weak self] (_, _, error) in
			
			guard let self = self else { return }
			
			switch CloudKitZoneResult.resolve(error) {
			case .success:
				DispatchQueue.main.async {
					completion(.success(()))
				}
			case .zoneNotFound:
				self.createZoneRecord() { result in
					switch result {
					case .success:
						self.modify(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, completion: completion)
					case .failure(let error):
						completion(.failure(error))
					}
				}
			case .userDeletedZone:
				DispatchQueue.main.async {
					completion(.failure(CloudKitZoneError.userDeletedZone))
				}
			case .retry(let timeToWait):
				self.retryOperationIfPossible(retryAfter: timeToWait) {
					self.modify(recordsToSave: recordsToSave, recordIDsToDelete: recordIDsToDelete, completion: completion)
				}
			case .limitExceeded:
				let chunkedRecords = recordsToSave.chunked(into: 300)
				for chunk in chunkedRecords {
					self.modify(recordsToSave: chunk, recordIDsToDelete: recordIDsToDelete, completion: completion)
				}
			default:
				DispatchQueue.main.async {
					completion(.failure(error!))
				}
			}
		}
		
		database?.add(op)
	}
	
    func fetchChangesInZone(completion: @escaping (Result<Void, Error>) -> Void) {

		refreshProgress?.addToNumberOfTasksAndRemaining(1)

		let zoneConfig = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
		zoneConfig.previousServerChangeToken = changeToken
		let op = CKFetchRecordZoneChangesOperation(recordZoneIDs: [Self.zoneID], configurationsByRecordZoneID: [Self.zoneID: zoneConfig])
        op.fetchAllChanges = true

        op.recordZoneChangeTokensUpdatedBlock = { [weak self] zoneId, token, _ in
            guard let self = self else { return }
			DispatchQueue.main.async {
				self.changeToken = token
			}
        }

        op.recordChangedBlock = { [weak self] record in
            guard let self = self else { return }
			DispatchQueue.main.async {
				self.delegate?.cloudKitDidChange(record: record)
			}
        }

        op.recordWithIDWasDeletedBlock = { [weak self] recordId, recordType in
            guard let self = self else { return }
			DispatchQueue.main.async {
				self.delegate?.cloudKitDidDelete(recordType: recordType, recordID: recordId)
			}
        }

        op.recordZoneFetchCompletionBlock = { [weak self] zoneId ,token, _, _, error in
            guard let self = self else { return }

			switch CloudKitZoneResult.resolve(error) {
            case .success:
				DispatchQueue.main.async {
					self.changeToken = token
				}
			 case .retry(let timeToWait):
				 self.retryOperationIfPossible(retryAfter: timeToWait) {
					 self.fetchChangesInZone(completion: completion)
				 }
			 default:
				os_log(.error, log: self.log, "%@ zone fetch changes error: %@.", zoneId.zoneName, error?.localizedDescription ?? "Unknown")
			}
        }

        op.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
			DispatchQueue.main.async {
				self?.refreshProgress?.completeTask()
				if let error = error {
					completion(.failure(error))
				} else {
					completion(.success(()))
				}
			}
        }

        database?.add(op)
    }
	
}

private extension CloudKitZone {
	
	var changeTokenKey: String {
		return "cloudkit.server.token.\(Self.zoneID.zoneName)"
	}

    var changeToken: CKServerChangeToken? {
        get {
			guard let tokenData = UserDefaults.standard.object(forKey: changeTokenKey) as? Data else { return nil }
			return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: tokenData)
        }
        set {
            guard let token = newValue, let data = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false) else {
                UserDefaults.standard.removeObject(forKey: changeTokenKey)
                return
            }
            UserDefaults.standard.set(data, forKey: changeTokenKey)
        }
    }

	var zoneConfiguration: CKFetchRecordZoneChangesOperation.ZoneConfiguration {
		let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
		config.previousServerChangeToken = changeToken
		return config
    }
	
	func createZoneRecord(completion: @escaping (Result<Void, Error>) -> Void) {
		database?.save(CKRecordZone(zoneID: Self.zoneID)) { (recordZone, error) in
			if let error = error {
				DispatchQueue.main.async {
					completion(.failure(error))
				}
			} else {
				DispatchQueue.main.async {
					completion(.success(()))
				}
			}
		}
	}

	func retryOperationIfPossible(retryAfter: Double, block: @escaping () -> ()) {
		let delayTime = DispatchTime.now() + retryAfter
		DispatchQueue.main.asyncAfter(deadline: delayTime, execute: {
			block()
		})
	}

}
