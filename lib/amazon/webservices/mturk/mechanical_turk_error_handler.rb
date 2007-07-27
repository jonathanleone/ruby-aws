# Copyright:: Copyright (c) 2007 Amazon Technologies, Inc.
# License::   Apache License, Version 2.0

require 'amazon/util/logging'
require 'amazon/webservices/util/validation_exception'
require 'amazon/webservices/util/unknown_result_exception'

module Amazon
module WebServices
module MTurk

class MechanicalTurkErrorHandler
  include Amazon::Util::Logging

  REQUIRED_PARAMETERS = [:Relay]

  def initialize( args )
    missing_parameters = REQUIRED_PARAMETERS - args.keys
    raise "Missing paramters: #{missing_parameters.join(',')}" unless missing_parameters.empty?
    @relay = args[:Relay]
  end

  def dispatch(method, *args)
    try = 0
    begin
      try += 1
      log "Dispatching call to #{method} (try #{try})"
      response = @relay.send(method,*args)
      validateResponse( response )
      return response
    rescue Exception => error
      case handleError( error,method )
      when :RetryWithBackoff
        retry if doBackoff( try )
      when :RetryImmediate
        retry if canRetry( try )
      when :Ignore
        return :IgnoredError => error
      when :Unknown
        raise Util::UnknownResultException.new( error, method, *args )
      when :Fail
        # fall through
      else
        raise "Unknown error handling method: #{handleError( error,method )}"
      end
      raise error
    end
  end

  RETRY_PRE = %w( search get register update disable assign set dispose )

  def methodRetryable( method )
    RETRY_PRE.each do |pre|
      return true if method.to_s =~ /^#{pre}/i
    end
    return false
  end

  def handleError( error, method )
    log "Handling error: #{error.inspect}"
    case error.class.to_s
    when 'Timeout::Error','SOAP::HTTPStreamError'
      if methodRetryable( method )
        return :RetryImmediate
      else
        return :Unknown
      end
    when 'SOAP::FaultError'
      case error.faultcode.data
      when "aws:Server.ServiceUnavailable"
        return :RetryWithBackoff
      else
        return :Unkown
      end
    when 'Amazon::WebServices::Util::ValidationException'
      return :Fail
    when 'RuntimeError'
      case error.message
      when 'Throttled'
        return :RetryWithBackoff
      else
        return :RetryImmediate
      end
    else
      return :Unknown
    end
  end

  MAX_RETRY = 6
  BACKOFF_EXPONENT = 2
  BACKOFF_INITIAL = 0.1

  def canRetry( try )
    try <= MAX_RETRY
  end

  def doBackoff( try )
    return false unless canRetry(try)
    delay = BACKOFF_INITIAL * ( BACKOFF_EXPONENT ** try )
    sleep delay
    return true
  end

  RESULT_PATTERN = /Result/
  ACCEPTABLE_RESULTS = %w( HIT Qualification QualificationType QualificationRequest Information )

  def isResultTag( tag )
    tag.to_s =~ RESULT_PATTERN or ACCEPTABLE_RESULTS.include?( tag.to_s )
  end

  def validateResponse(response)
    log "Validating response: #{response.inspect}"
    raise 'Throttled' if response[:Errors] and response[:Errors][:Error] and response[:Errors][:Error][:Code] == "ServiceUnavailable"
    raise Util::ValidationException.new(response) unless response[:OperationRequest][:Errors].nil?
    resultTag = response.keys.find {|r| isResultTag( r ) }
    raise Util::ValidationException.new(response, "Didn't get back an acceptable result tag (got back #{response.keys.join(',')})") if resultTag.nil?
    log "using result tag <#{resultTag}>"
    result = response[resultTag]
    raise Util::ValidationException.new(response) unless result[:Request][:Errors].nil?
    response
  end

end # MechanicalTurkErrorHandler

end # Amazon::WebServices::MTurk
end # Amazon::WebServices
end # Amazon
