import Foundation
import Shared
import Alamofire

private let _singleton = AdBlocker()

class AdBlocker {
    static let prefKeyAdBlockOn = "braveBlockAds"
    static let prefKeyAdBlockOnDefaultValue = true
    static let dataVersion = "1"
    let dataUrl = NSURL(string: "https://s3.amazonaws.com/adblock-data/\(dataVersion)/ABPFilterParserData.dat")!
    let dataFile = "abp-data-\(dataVersion).dat"

    // Store the last 500 URLs checked
    // Store 10 x 50 URLs in the array called timeOrderedCacheChunks. This is a FIFO array,
    // Throw out a 50 URL chunk when the array is full
    var fifoOfCachedUrlChunks: [NSMutableDictionary] = []
    let maxChunks = 10
    let maxUrlsPerChunk = 50
    var isEnabled = true

    private init() {
        NSNotificationCenter.defaultCenter().addObserver(self, selector: "prefsChanged:", name: NSUserDefaultsDidChangeNotification, object: nil)
        updateEnabledState()
    }

    class var singleton: AdBlocker {
        return _singleton
    }

    func showError(error: String) {
        UIAlertView(title: "Adblocker Error", message: error, delegate: nil, cancelButtonTitle: "Close").show()
    }

    // return the dir and a bool if the dir was created
    func dataDir() -> (String, Bool)  {
        if let dir = NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory.DocumentDirectory, NSSearchPathDomainMask.UserDomainMask, true).first {
            let path = dir + "/abp-data"
            var wasCreated = false
            if !NSFileManager.defaultManager().fileExistsAtPath(path) {
                do {
                    try NSFileManager.defaultManager().createDirectoryAtPath(path, withIntermediateDirectories: false, attributes: nil)
                } catch let error as NSError {
                    showError("dataDir(): \(error.localizedDescription)")
                }
                wasCreated = true
            }
            return (path, wasCreated)
        } else {
            showError("Can't get documents dir.")
            return ("", false)
        }
    }

    func etagFileNameFromDataFile(dataFileName: String) -> String {
        return dataFileName + ".etag"
    }

    func readDataEtag() -> String? {
        let (dir, _) = dataDir()
        let path = etagFileNameFromDataFile(dir + "/" + dataFile)
        if !NSFileManager.defaultManager().fileExistsAtPath(path) {
            return nil
        }
        guard let data = NSFileManager.defaultManager().contentsAtPath(path) else { return nil }
        return NSString(data: data, encoding: NSUTF8StringEncoding) as? String
    }

    func writeData(data: NSData, etag: String?) {
        let (dir, wasCreated) = dataDir()
        // If dir existed already, clear out the old one
        if !wasCreated {
            do {
                try NSFileManager.defaultManager().removeItemAtPath(dir)
            } catch let error as NSError {
                print("writeData: \(error.localizedDescription)")
            }
            dataDir() // to re-create the directory
        }

        let path = dir + "/" + dataFile
        if !data.writeToFile(path, atomically: true) {
            showError("Failed to write data to \(path)")
        }

        if let etagData = etag?.dataUsingEncoding(NSUTF8StringEncoding) {
            let etagPath = etagFileNameFromDataFile(path)
            if !etagData.writeToFile(etagPath, atomically: true) {
                showError("Failed to write data to \(etagPath)")
            }
        }
    }

    func readData() -> NSData? {
        let (dir, _) = dataDir()
        let path = dir + "/" + dataFile
        if !NSFileManager.defaultManager().fileExistsAtPath(path) {
            return nil
        }
        return NSFileManager.defaultManager().contentsAtPath(path)
    }


    func loadData() {

        func networkRequest(forceDownload force: Bool) {
            if !force && AdBlockCppFilter.singleton().hasAdblockDataFile() {
                return
            }
            let session = NSURLSession.sharedSession()
            let task = session.dataTaskWithURL(dataUrl) {
                (data, response, error) -> Void in
                if let err = error {
                    print(err.localizedDescription)
                    delay(60) {
                        // keep trying every minute until successful
                        networkRequest(forceDownload: force)
                    }
                }
                else {
                    if let data = data, response = response as? NSHTTPURLResponse {
                        let etag = response.allHeaderFields["Etag"] as? String
                        self.writeData(data, etag: etag)
                        AdBlockCppFilter.singleton().setAdblockDataFile(data)
                    }
                }
            }
            task.resume()
        }

        let data = readData()
        if data != nil {
            AdBlockCppFilter.singleton().setAdblockDataFile(data)
            delay(5.0) { // a few seconds after startup, check to see if a new file is available
                Alamofire.request(.HEAD, self.dataUrl).response {
                    request, response, data, error in
                    if let err = error {
                        print("\(err.localizedDescription)")
                    } else {
                        guard let etag = response?.allHeaderFields["Etag"] as? String else { return }
                        let etagOnDisk = self.readDataEtag()
                        if etagOnDisk != etag {
                            networkRequest(forceDownload: true)
                        }
                    }
                }
            }
            return
        }

        networkRequest(forceDownload: false)
    }

    func updateEnabledState() {
        let obj = BraveApp.getPref(AdBlocker.prefKeyAdBlockOn)
        isEnabled = obj as? Bool ?? AdBlocker.prefKeyAdBlockOnDefaultValue
    }

    @objc func prefsChanged(info: NSNotification) {
        updateEnabledState()
    }

    func shouldBlock(request: NSURLRequest) -> Bool {
        // synchronize code from this point on.
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        if !isEnabled {
            return false
        }

        guard let url = request.URL,
            domain = request.mainDocumentURL?.host else {
                return false
        }

        if let host = url.host where host.contains(domain) {
            return false
        }

        // A cache entry is like: timeOrderedCacheChunks[0]["www.microsoft.com_http://some.url"] = true/false for blocking
        let key = "\(domain)_\(url.absoluteString)"

        for urls in fifoOfCachedUrlChunks {
            if let urlIsBlocked = urls[key] {
                if urlIsBlocked as! Bool {
                    #if LOG_AD_BLOCK
                        print("blocked (cached result) \(url.absoluteString)")
                    #endif
                }
                return urlIsBlocked as! Bool
            }
        }

        let isBlocked = AdBlockCppFilter.singleton().checkWithCppABPFilter(url.absoluteString,
            mainDocumentUrl: domain,
            acceptHTTPHeader:request.valueForHTTPHeaderField("Accept"))

        if fifoOfCachedUrlChunks.count > maxChunks {
            fifoOfCachedUrlChunks.removeFirst()
        }

        if fifoOfCachedUrlChunks.last == nil || fifoOfCachedUrlChunks.last?.count > maxUrlsPerChunk {
            fifoOfCachedUrlChunks.append(NSMutableDictionary())
        }
        
        if let cacheChunkUrlAndDomain = fifoOfCachedUrlChunks.last {
            cacheChunkUrlAndDomain[key] = isBlocked
        }
        
        #if LOG_AD_BLOCK
            if isBlocked {
                print("blocked \(url.absoluteString)")
            }
        #endif
        
        return isBlocked
    }
}