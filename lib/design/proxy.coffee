assert = require('assert')
path = require('path')
fs = require('fs')
_ = require('lodash')
express = require('express')
request = require('request')
mime = require('mime')
tar = require('tar-stream')
gunzip = require('gunzip-maybe')
log = require('npmlog')
eos = require('end-of-stream')

exports.start = (options, callback) ->
  assert(options.host, 'proxy.start(options, callback) requires a options.host param.')
  assert(options.port, 'proxy.start(options, callback) requires a options.port param.')
  basePath = undefined

  log.verbose('design:proxy', 'Ensure that cache directory exists')
  fs.mkdir options.cacheDirectory, (err) ->
    return callback(err) if err && err.code != 'EEXIST'

    log.verbose('design:proxy', 'Initialize webserver')
    app = express()
    app.response.error = (err) ->
      log.error('design:proxy', err)
      @status(500).send
        status: 500
        message: err.message
        stack: err.stack

    app.use (req, res, next) ->
      res.header('Access-Control-Allow-Origin', '*')
      res.header('Access-Control-Allow-Methods', "OPTIONS, GET, PUT, POST, PATCH, DELETE")

      if req.method == 'OPTIONS'
        res.header('Access-Control-Allow-Headers', "Cache-Control, Pragma, Origin, Authorization, Content-Type, X-Requested-With")
        log.verbose('design:proxy', "Serving CORS request received on '#{req.path}', requested by #{req.ip}")
        return res.sendStatus(204)

      log.verbose('design:proxy', "Serving '#{req.method} #{req.url}', requested by #{req.ip}")
      next()

    # serve development designs
    if options.devDirectory
      build = require('../build')
      serveJSON = (name, version) ->
        (req, res) ->
          callbacked = 0
          design = build(src: options.devDirectory)
          design.on 'error', (err) ->
            log.error('error', err)
            res.error(err) if !callbacked++

          design.on 'end', ->
            log.info('design:proxy', "Serve development design #{name}@#{version}")
            res.set('content-type', 'application/json')
            res.send(design.toJson()) if !callbacked++

      serveAsset = (name, version) ->
        (req, res) ->
          filePath = path.join(options.devDirectory, req.params.file)
          stream = fs.createReadStream(filePath)
          contentType = mime.lookup(filePath)
          sendFile(res)(null, {stream, contentType})

      try
        designPath = path.join(options.devDirectory, 'config')
        {version, name} = require(designPath)
      catch err
        log.error('design:proxy', "Failed to load development design in '#{designPath}.'")

      log.info('design:proxy', "Found local design #{name}@#{version}")
      app.get("/designs/#{name}/#{version}", serveJSON(name, version))
      app.get("/designs/#{name}/#{version}/:file(*)", serveAsset(name, version))


    # serve proxied designs
    app.get '/designs/:name/:version', (req, res) ->
      name = req.params.name
      version = req.params.version
      getDesignFileStream
        host: options.host
        name: name
        version: version
        file: 'design.json'
        cacheDirectory: options.cacheDirectory
      , (err, {stream, contentType} = {}) ->
        if err
          sendFile(res)(err)

        else if !stream
          log.info('design:proxy', "Could not find the file 'package.json' in the design '#{name}@#{version}'") unless stream
          sendFile(res)()

        else
          log.info('design:proxy', "Serve cached design #{name}@#{version}")
          stream = stream.pipe(new DesignTransform({name, version, basePath}))
          sendFile(res)(null, {stream, contentType})


    app.get '/designs/:name/:version/:file(*)', (req, res) ->
      getDesignFileStream
        host: options.host
        name: req.params.name
        version: req.params.version
        file: req.params.file
        cacheDirectory: options.cacheDirectory
      , (err, {stream, contentType} = {}) ->
        if err
          sendFile(res)(err)

        else if !stream
          log.info('design:proxy', "Could not find the file '#{req.params.file}' in the design '#{req.params.name}@#{req.params.version}'") unless stream
          sendFile(res)()

        else
          sendFile(res)(null, {stream, contentType})


    server = app.listen options.port, (err) ->
      if err
        callback(err, server: server)

      else
        port = server.address().port
        basePath = "http://localhost:#{port}/designs"
        callback(null, server: server, port: port)


sendFile = (res) ->
  (err, {stream, contentType} = {}) ->
    return res.error(err) if err
    return res.sendStatus(404) if !stream
    res.set('content-type', contentType)
    stream
    .on 'error', (err) -> res.error(err)
    .pipe(res)


getDesignStream = (options, callback) ->
  filePath = path.join(options.cacheDirectory, "#{options.name}-#{options.version}.tar.gz")
  tmpFilePath = filePath+'.tmp'

  fs.exists filePath, (exists) ->
    if exists
      log.verbose('design:proxy', "Loading design '#{filePath}'")
      return callback(null, fs.createReadStream(filePath))

    log.verbose('design:proxy', "Design #{options.name}@#{options.version} is not cached.")
    tarUrl = "#{options.host}/designs/#{options.name}/#{options.version}.tar.gz"
    log.verbose('design:proxy', "Fetching '#{tarUrl}'")

    request(method: 'get', url: tarUrl)
    .on 'error', (err) ->
      log.error('design:proxy', "Failed to fetch '#{tarUrl}'")
      callback(err)

    .on 'response', (res) ->
      if res.statusCode != 200
        msg = "Failed to fetch '#{tarUrl}'. Received statusCode #{res.statusCode}"
        log.error('design:proxy', msg)
        callback(new Error(msg))

      else if !_.contains(res.headers, 'gzip')
        msg = "Failed to fetch '#{tarUrl}'. Did not receive a tar archive."
        log.error('design:proxy', msg)
        callback(new Error(msg))

      else
        write = fs.createWriteStream(tmpFilePath)
        callbacked = false
        cleanup = (err) ->
          return if callbacked
          callbacked = true
          fs.unlink tmpFilePath, -> log.error('design:proxy', err)
          callback(err)

        eos write, (err) ->
          return cleanup(err) if err
          log.verbose('design:proxy', "Successfully downloaded '#{tarUrl}' to '#{tmpFilePath}'. Moving tmp file to '#{filePath}'")

          fs.rename tmpFilePath, filePath, (err) ->
            return cleanup(err) if err
            log.info('design:proxy', "Successfully cached '#{tarUrl}'")
            getDesignStream(options, callback)

        eos res, (err) ->
          return cleanup(err) if err

        res.pipe(write)


getDesignFileStream = ({name, version, host, file, cacheDirectory}, callback) ->
  callback = _.once(callback)
  extract = tar.extract()

  log.verbose('design:proxy', "Requested the file '#{file}' from the design '#{name}@#{version}'")
  extract.on 'entry', (header, stream, done) ->
    if header.name != "undefined/#{file}"
      stream.resume()
      done()

    else
      log.verbose('design:proxy', "Found the file '#{file}' in the design '#{name}@#{version}'")
      contentType = mime.lookup(header.name)
      callback(null, {contentType, stream})

      destroy = ->
        stream.destroy()
        extract.destroy()

      stream.on 'error', destroy
      stream.on 'end', destroy

  extract.on 'finish', -> callback()
  getDesignStream {name, version, host, cacheDirectory}, (err, stream) ->
    if err || !stream
      return callback(err)

    stream.pipe(gunzip()).pipe(extract)



class DesignTransform extends require('stream').Transform

  constructor: ({@name, @version, @basePath}) ->
    super()


  _transform: (buffer, encoding, done) ->
    try
     object = JSON.parse(buffer.toString())
     object.assets ?= {}
     object.assets.basePath = "#{@basePath}/#{@name}/#{@version}"
     json = JSON.stringify(object)
    catch err
      return done(err)

    done(null, json)

