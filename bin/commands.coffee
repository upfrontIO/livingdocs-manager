log = require('npmlog')
path = require('path')
_ = require('lodash')
pkg = require('../package.json')
minimist = require('minimist')
print = require('../lib/print')
config = require('./config')


execAction = ({identifier, method, message}) ->
  ->
    authenticateProject (err, {options, token} = {}) ->
      return log.error("project:design:#{identifier}", err) if err
      api = require('../lib/api')
      api.project[method]
        host: options.host
        token: token
      ,
        projectId: options.project
        design:
          name: options.name
          version: options.version
      , (err) ->
        return log.error("project:design:#{identifier}", err) if err
        log.info("project:design:#{identifier}", message.replace('{{design}}', "#{options.name}@#{options.version}"))


exports.init = (callback) ->
  callback()


exports.trigger = (command='help') ->
  action = commands[command]
  action = action() if _.isFunction(action)
  if action
    action.exec?()

  else
    log.error('cli', "The command '#{command}' isn't available")
    console.log('')
    commands.help.exec()


commands =

  '-h': -> commands.help
  '--help': -> commands.help
  help:
    description: 'Show this information'
    exec: ->
      print
        .line('Usage', 'ldm <command>')()
        .line('where','<command> is one of:')

      previousTopic = undefined
      _.each commands, (command, key) ->
        return unless command?.description
        topic = key.split(':')?[0]
        print.line() if topic != previousTopic
        print.line("  #{_.padRight(key, 30)}#  #{command.description}")
        previousTopic = topic


  '-v': -> commands.version
  '--version': -> commands.version
  version:
    description: 'Show the cli version'
    exec: ->
      console.log(pkg.version)


  'user:info':
    description: 'Prints the user information'
    exec: ->
      authenticate (err, {host, user, token} = {}) ->
        return log.error('user:info', err) if err
        print.topic('User').user(user)()
        print.topic('Access token').line(token)()


  'build': ->
    log.warn('`ldm build` is obsolete. Please use `ldm design:build`.')
    commands['design:build']


  'design:build':
    description: 'Compile the design'
    exec: ->
      argv = process.argv.slice(3)
      args = minimist argv,
        string: ['source', 'destination']
        alias:
          s: 'source'
          src: 'source'
          d: 'destination'
          dst: 'destination'
          dest: 'destination'

      args.source = args._[0] || process.cwd()
      args.destination = args._[1] || process.cwd()

      error = null
      Design = require('../')
      Design.build(src: args.source, dest: args.destination)
      .on 'debug', (debug) ->
        log.verbose('build', debug)

      .on 'warn', (warning) ->
        log.warn('build', warning)

      .on 'error', (err) ->
        error = err

      .on 'end', ->
        if error
          log.error('design:build', error)
        else
          log.info('design:build', 'Design compiled...')

        callback?(error)


  'publish': ->
    log.warn('`ldm publish` is obsolete. Please use `ldm design:publish`.')
    commands['design:publish']


  'design:publish':
    description: 'Show the script version'
    exec: ->
      args = minimist process.argv.slice(3),
        string: ['source']
        alias: s: 'source', src: 'source'


      args.source ?= args._[0] || process.cwd()
      authenticate (err, {token, host} = {}) ->
        return log.error('design:publish', 'Failed to authenticate', err) if err
        upload = require('../lib/upload')
        upload.exec
          host: host
          token: token
          cwd: args.source
        , (err, {design, url} = {}) ->
          if err?.code == 'ENOENT'
            log.error('design:publish', 'No design.json file found in %s', args.source)

          else if err
            log.error('design:publish', err)

          else
            log.info('design:publish', 'Published the design %s@%s to %s', design.name, design.version, url)


  'design:server': -> commands['design:proxy']
  'design:proxy':
    description: 'Start a design server that caches designs for offline use'
    exec: ->
      args = minimist process.argv.slice(3),
        string: ['host', 'port']
        alias: h: 'host', p: 'port'

      opts =
        host: args.host || 'https://api.livingdocs.io'
        port: args.port || 3000
        directory: path.join(process.cwd(), args._[0] || '.') if args._[0]

      log.info('design:proxy', 'Proxying %s', opts.host)
      proxy = require('../lib/design/proxy')
      proxy.start
        host: opts.host
        port: opts.port
        cacheDirectory: path.join(config.cache, 'design-proxy')
        devDirectory: opts.directory
      , (err, {server, port} = {}) ->
        if err?.code == 'EADDRINUSE'
          log.error('design:proxy', 'Failed to start the server on port %s', opts.port)

        else if err
          log.error('design:proxy', err)

        else
          log.info('design:proxy', 'Server started on http://localhost:%s', port)


  ## feature requests:
  # project:design:default     Set a design to a default
  # project:design:deprecate   Prevent document creation with a specific design version

  'project:design:list':
    description: 'List all designs of a project'
    exec: ->
      authenticateProject (err, {options, token} = {}) ->
        return log.error('project:design:list', err) if err
        api = require('../lib/api')
        api.project.listDesigns
          host: options.host
          token: token
        ,
          options.project
        , (err, {defaultDesign, designs} = {}) ->
          return log.error('project:design:list', err) if err
          print.topic('Default design').design(defaultDesign)()
          print.topic('Designs').each(designs, print.design)()


  'project:design:add':
    description: 'Add a design to a project'
    exec: execAction
      method: 'addDesign'
      identifier: 'add'
      message: "The design {{design}} is now linked to your project."


  'project:design:remove':
    description: 'Remove a design from a project'
    exec: execAction
      method: 'removeDesign'
      identifier: 'remove'
      message: "The design {{design}} got removed from your project."


  'project:design:default':
    description: 'Set a design as default'
    exec: execAction
      method: 'setDefaultDesign'
      identifier: 'default'
      message: "The design {{design}} is now set as default."


  'project:design:enable':
    description: "Enable project's design"
    exec: execAction
      method: 'enableDesign'
      identifier: 'enable'
      message: "The design {{design}} is now enabled for your project."


  'project:design:disable':
    description: "Disable project's design"
    exec: execAction
      method: 'disableDesign'
      identifier: 'disable'
      message: "The design {{design}} is now disabled for your project."


authenticate = (callback) ->
  defaults = minimist process.argv.slice(3),
    string: ['user', 'password', 'host']
    default:
      host: config.host
      user: config.user
      dir: config.dir # configdir
      configs: config.configs # existing configfiles
    alias:
      h: 'host'
      u: 'user'
      p: 'password'

  api = require('../lib/api')
  api.askAuthenticationOptions defaults, (options) ->
    api.authenticate
      host: options.host
      user: options.user
      password: options.password
    , (err, {user, token} = {}) ->
      return callback(err) if err
      callback(null, {user, token, host: options.host})


authenticateProject = (callback) ->
  c = minimist process.argv.slice(3),
    string: ['project', 'name', 'version']
    alias:
      s: 'project'
      project: 'project'
      n: 'name'

  if Array.isArray(c.project)
    c.project = c.project.pop()

  authenticate (err, {user, token, host} = {}) ->
    return callback(err) if err
    callback null,
      token: token
      options:
        host: host
        project: c.project || user.project_id || user.space_id
        name: c.name
        version: c.version
