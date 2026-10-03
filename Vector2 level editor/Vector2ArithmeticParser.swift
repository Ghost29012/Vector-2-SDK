//
//  Vector2ArithmeticParser.swift
//  Vector2 level editor
//
//  Vector 2 library XML sometimes stores tiny arithmetic expressions instead
//  of plain numbers. This parser handles only +, -, *, /, parentheses, signs,
//  and decimal numbers. This handles arithmetic only, not scripts.
//

import Foundation

struct Vector2ArithmeticParser {
    let characters: [Character]
    var index = 0

    mutating func parse() -> Double? {
        guard let value = expression() else { return nil }
        skipSpaces()
        return index == characters.count ? value : nil
    }

    private mutating func expression() -> Double? {
        guard var value = term() else { return nil }
        while true {
            skipSpaces()
            if consume("+") {
                guard let rhs = term() else { return nil }
                value += rhs
            } else if consume("-") {
                guard let rhs = term() else { return nil }
                value -= rhs
            } else {
                return value
            }
        }
    }

    private mutating func term() -> Double? {
        guard var value = factor() else { return nil }
        while true {
            skipSpaces()
            if consume("*") {
                guard let rhs = factor() else { return nil }
                value *= rhs
            } else if consume("/") {
                guard let rhs = factor(), abs(rhs) > .ulpOfOne else { return nil }
                value /= rhs
            } else {
                return value
            }
        }
    }

    private mutating func factor() -> Double? {
        skipSpaces()
        if consume("+") { return factor() }
        if consume("-") { return factor().map(-) }
        if consume("(") {
            guard let value = expression() else { return nil }
            skipSpaces()
            guard consume(")") else { return nil }
            return value
        }
        let start = index
        while index < characters.count,
              characters[index].isNumber || characters[index] == "." || characters[index] == "," {
            index += 1
        }
        guard index > start else { return nil }
        return Double(String(characters[start..<index]).replacingOccurrences(of: ",", with: "."))
    }

    private mutating func skipSpaces() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }
}
