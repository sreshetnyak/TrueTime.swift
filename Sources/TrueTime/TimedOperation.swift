//
//  TimedOperation.swift
//  TrueTime
//
//  Created by Michael Sanders on 7/18/16.
//  Copyright © 2016 Instacart. All rights reserved.
//

import Foundation

protocol TimedOperation: AnyObject {
    var started: Bool { get }
    var timeout: TimeInterval { get }
    var timer: DispatchSourceTimer? { get set }
    var timerQueue: DispatchQueue { get }
    
    func timeoutError(_ error: NSError)
}

extension TimedOperation {
    func startTimer() {
        cancelTimer()
        timer = DispatchSource.makeTimerSource(flags: [], queue: timerQueue)
        timer?.schedule(deadline: .now() + timeout)
        timer?.setEventHandler {
            guard self.started else { return }
            self.timeoutError(NSError(trueTimeError: .timedOut))
        }
        timer?.resume()
    }

    func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}