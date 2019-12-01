//
//  RequestMaker.swift
//  MeatNetworking
//
//  Created by Karl Söderberg on 2019-10-16.
//  Copyright © 2019 AppMeat AB. All rights reserved.
//

import Foundation

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
            throw FutureError.noData
        }
        
        // If raw Data expected just return sessionData
        if let data = validatedSessionData as? T {
            return data
        }
        
        do {
            return try request.configuration.decoder.decode(T.self, from: validatedSessionData)
        } catch {
            print(error)
            throw error as? FutureError ?? FutureError.dataDecodingError
        }
    }
    
    public static func performRequest(request: Requestable) throws -> (HTTPURLResponse?, Data?) {
        var sessionData: Data?
        var sessionError: Error?
        var sessionResponse: HTTPURLResponse?
        let group = DispatchGroup()
        let urlReq = try urlRequest(from: request)
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
        
        if let error = sessionError {
            
            guard error._code != URLError.cancelled.rawValue else {
                throw FutureError.cancelled
            }
            
            if let unauthorizedError = UnauthorizedError(code: sessionResponse?.statusCode) {
                if request.logOutIfUnauthorized {
                    request.configuration.defaultUnathorizedAccessHandler?()
                }
                throw unauthorizedError
            }
            
            if let warning = sessionResponse?.getWarning() {
                throw FutureError.warning(warning, sessionData)
            }
            
            throw error
        }
        return (sessionResponse, sessionData)
    }
    
    private static func urlRequest(from request: Requestable) throws -> URLRequest {
        var url = request.configuration.getURL(path: request.path, credentials: request.credentials)
        
        if request.method.shouldAppendQueryString() {
            url = url.appendingQueryParameters(request.parameters)
        }
        
        var urlRequest = URLRequest(url: url)
        
        // HTTP Method
        urlRequest.httpMethod = request.method.rawValue
        
        // Headers
        request.headerFields.allValues.forEach {
            urlRequest.setValue($0.value, forHTTPHeaderField: $0.key)
        }
        
        
        if let parameters = request.parameters, request.method.shouldAddHTTPBody() {
            // Parameters
            switch request.headerFields.contentType {
            case .json:
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: parameters, options: [])
            case .form:
                urlRequest.httpBody = parameters.percentEscaped().data(using: .utf8)
            }
        }
        
        return urlRequest
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
