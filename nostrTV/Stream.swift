//
//  Stream.swift
//  nostrTV
//
//  Created by Taymur Khumush on 4/24/25.
//

import Foundation

struct Stream: Identifiable, Codable, Equatable {
    let streamID: String          // from the "d" tag
    let title: String
    let streaming_url: String

    var id: String { streamID }

    static func == (lhs: Stream, rhs: Stream) -> Bool {
        return lhs.streamID == rhs.streamID
    }
}
