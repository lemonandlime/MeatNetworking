//
//  RequestMaker.swift
//  MeatNetworking
//
//  Created by Karl Söderberg on 2019-10-16.
//  Copyright © 2019 AppMeat AB. All rights reserved.
//

import Foundation
import MeatFutures

public class RequestMaker {
    
    static func performRequest<T: Decodable>(request: Requestable, expecting: T.Type) throws -> T {
        
        let response: (response: HTTPURLResponse?, data: Data?) = try self.performRequest(request: request)
        
        storeCookie(from: response.response)
        
        // If no data expected just return
        if let void = VoidResult() as? T {
            return void
        }
        
        // Check if we have any sessionData else throw nodata error
        guard let validatedSessionData = response.data else {
            throw NetworkingError.notFound
        }
        
        // If raw Data expected just return sessionData
        if let data = validatedSessionData as? T {
            return data
        }
        
        do {
            return try request.configuration.decoder.decode(T.self, from: validatedSessionData)
        } catch {
            print(error)
            throw NetworkingError(underlyingError: error, data: validatedSessionData)
        }
    }
    
    public static func performRequest(request: Requestable) throws -> (HTTPURLResponse?, Data?) {
        var sessionData: Data?
        var sessionError: Error?
        var sessionResponse: HTTPURLResponse?
        let group = DispatchGroup()
        let urlReq = try request.build()
        
        group.enter()
        let task = URLSession.shared.dataTask(with: urlReq) { data, response, error in
            sessionData = data
            sessionError = error
            sessionResponse = response as? HTTPURLResponse
            group.leave()
        }
        
        task.resume()
        request.setIsRunning(true)
        group.wait()
        request.setIsRunning(false)
        
        if let networkError = NetworkingError(error: sessionError, response: sessionResponse, data: sessionData) {
            if request.logOutIfUnauthorized, networkError.isUnauthorized {
                request.configuration.defaultUnathorizedAccessHandler?()
            }
            throw networkError
        }
        
        return (sessionResponse, sessionData)
    }
    
    private static func storeCookie(from response: HTTPURLResponse?) {
        guard   let url = response?.url,
            let headerFields = response?.allHeaderFields as? [String : String] else {
                return
        }
        
        if let cookie = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url).first {
            print("Storing cookie for \(url.path)")
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }
}

private extension Requestable {
    func build() throws ->  URLRequest {
        
        guard var url = URL(string: configuration.baseURL)?
            .appendingPathComponent(path.toString)
            .appendingQueryParameters(configuration.defaultQueryParameters)
            else {
                throw FutureError.badRequest
        }
        
        if method.shouldAppendQueryString() {
            url.appendQueryParameters(parameters)
        }
        
        var urlRequest = URLRequest(url: url)
        
        if case .none = authentication, path.requiresAuthentication {
            throw NetworkingError.unauthorized
        }
        
        // HTTP Method
        urlRequest.addAuthentication(authentication)
        urlRequest.httpMethod = method.rawValue
        
        // Headers
        headerFields.allFields.forEach {
            urlRequest.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        
        
        if let parameters = parameters, method.shouldAddHTTPBody() {
            // Parameters
            switch headerFields.contentType {
            case .json:
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: [])
            case .form:
                urlRequest.httpBody = parameters.percentEscaped().data(using: .utf8)
            }
        }
        
        return urlRequest
    }
}

private extension URLRequest {
    mutating func addAuthentication(_ auth: Authentication) {
        switch auth {
        case .custom(let headerFields):
            headerFields.forEach {
                setValue($0.value, forHTTPHeaderField: $0.key)
            }
        case .OAuth2(let token):
            setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }
    }
}
