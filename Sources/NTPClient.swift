//
//  NTPClient.swift
//  TrueTime
//
//  Created by Michael Sanders on 10/12/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

struct NTPConfig {
    let timeout: TimeInterval
    let maxRetries: Int
    let maxConnections: Int
    let maxServers: Int
    let numberOfSamples: Int
    let pollInterval: TimeInterval
}

final class NTPClient {
    
    let config: NTPConfig
    
    init(config: NTPConfig) {
        self.config = config
    }

    func start(pool: [String], port: Int) {
        guard !pool.isEmpty else { return }
        guard self.reachability.callback == nil else { return }
        queue.async {
            self.pool = pool
            self.port = port
            self.reachability.callbackQueue = self.queue
            self.reachability.callback = self.updateReachability
            self.reachability.startMonitoring()
            self.startTimer()
        }
    }

    func pause() {
        queue.async {
            self.cancelTimer()
            self.reachability.stopMonitoring()
            self.reachability.callback = nil
            self.stopQueue()
        }
    }

    func fetchIfNeeded(queue callbackQueue: DispatchQueue,
                       first: ReferenceTimeCallback?,
                       completion: ReferenceTimeCallback?) {
        queue.async {
            guard self.reachability.callback != nil else { return }
            
            if let time = self.referenceTime {
                callbackQueue.async { first?(.success(time)) }
            } else if let first = first {
                self.startCallbacks.append((callbackQueue, first))
            }

            if let time = self.referenceTime, self.finished {
                callbackQueue.async { completion?(.success(time)) }
            } else {
                if let completion = completion {
                    self.completionCallbacks.append((callbackQueue, completion))
                }
                self.updateReachability(status: self.reachability.status ?? .notReachable)
            }
        }
    }

    private let referenceTimeLock: GCDLock<ReferenceTime?> = GCDLock(value: nil)
    
    var referenceTime: ReferenceTime? {
        get { return referenceTimeLock.read() }
        set { referenceTimeLock.write(newValue) }
    }

    private let queue = DispatchQueue(label: "com.instacart.ntp.client")
    private let reachability = Reachability()
    private var completionCallbacks: [(DispatchQueue, ReferenceTimeCallback)] = []
    private var connections: [NTPConnection] = []
    private var finished: Bool = false
    private var invalidated: Bool = false
    private var startCallbacks: [(DispatchQueue, ReferenceTimeCallback)] = []
    private var startTime: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var port: Int = 123
    private var pool: [String] = [] {
        didSet { invalidate() }
    }
}

private extension NTPClient {
    
    var started: Bool { return startTime != nil }
    
    func updateReachability(status: ReachabilityStatus) {
        switch status {
        case .notReachable:
            cancelTimer()
            finish(.failure(NSError(trueTimeError: .offline)))
        case .reachableViaWWAN, .reachableViaWiFi:
            startTimer()
            startPool(pool: pool, port: port)
        }
    }

    func startTimer() {
        cancelTimer()
        if let referenceTime = referenceTime {
            let remainingInterval = max(0, config.pollInterval - referenceTime.underlyingValue.uptimeInterval)
            timer = DispatchSource.makeTimerSource(flags: [], queue: queue)
            timer?.setEventHandler(handler: invalidate)
            timer?.schedule(deadline: .now() + remainingInterval)
            timer?.resume()
        }
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    func startPool(pool: [String], port: Int) {
        guard !started && !finished else { return }
        
        startTime = CFAbsoluteTimeGetCurrent()
        
        HostResolver.resolve(hosts: pool.map { ($0, port) },
                             timeout: config.timeout,
                             callbackQueue: queue) { resolver, result in
            
            guard self.started && !self.finished else { return }
            guard pool == self.pool, port == self.port else { return }
            
            switch result {
            case let .success(addresses): self.query(addresses: addresses, host: resolver.host)
            case let .failure(error): self.finish(.failure(error))
            }
        }
    }

    func stopQueue() {
        startTime = nil
        connections.forEach { $0.close(waitUntilFinished: true) }
        connections = []
    }

    func invalidate() {
        stopQueue()
        finished = false
        if referenceTime != nil , reachability.status != .notReachable && !pool.isEmpty {
            startPool(pool: pool, port: port)
        }
    }

    func query(addresses: [SocketAddress], host: String) {
        
        var results: [String: [FrozenNetworkTimeResult]] = [:]
        
        connections = NTPConnection.query(addresses: addresses,
                                          config: config,
                                          callbackQueue: queue) { connection, result in
            
            guard self.started && !self.finished else {
                return
            }

            let host = connection.address.host
            results[host] = (results[host] ?? []) + [result]

            let responses = Array(results.values)
            let sampleSize = responses.map { $0.count }.reduce(0, +)
            let expectedCount = addresses.count * self.config.numberOfSamples
            let atEnd = sampleSize == expectedCount
            let times = responses.map { results in
                results.compactMap { try? $0.get() }
            }

            if let time = bestTime(fromResponses: times) {
                let time = FrozenNetworkTime(networkTime: time, sampleSize: sampleSize, host: host)
                
                let referenceTime = self.referenceTime ?? ReferenceTime(time)
                if self.referenceTime == nil {
                    self.referenceTime = referenceTime
                } else {
                    referenceTime.underlyingValue = time
                }

                if atEnd {
                    self.finish(.success(referenceTime))
                } else {
                    self.updateProgress(.success(referenceTime))
                }
            } else if atEnd {
                let error: NSError
                if case let .failure(failure) = result {
                    error = failure as NSError
                } else {
                    error = NSError(trueTimeError: .noValidPacket)
                }

                self.finish(ReferenceTimeResult.failure(error))
            }
        }
    }

    func updateProgress(_ result: ReferenceTimeResult) {
        startCallbacks.forEach { queue, callback in
            queue.async {
                callback(result)
            }
        }
        
        startCallbacks = []
        NotificationCenter.default.post(Notification(name: .TrueTimeUpdated, object: self, userInfo: nil))
    }

    func finish(_ result: ReferenceTimeResult) {
        updateProgress(result)
        completionCallbacks.forEach { queue, callback in
            queue.async {
                callback(result)
            }
        }
        completionCallbacks = []
        finished = (try? result.get()) != nil
        stopQueue()
        startTimer()
    }
}
