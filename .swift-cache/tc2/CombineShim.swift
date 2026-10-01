import Foundation

public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct Published<Value> {
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
    public init(initialValue: Value) { self.wrappedValue = initialValue }
    public var wrappedValue: Value
}
