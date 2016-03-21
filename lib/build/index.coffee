path = require('path')
async = require('async')
Glob = require('glob').Glob

Design = require('./models/design')
_ = require('lodash')


defaultConfig = (config) ->
  _.extend {},
    src: undefined # absolute directory of design
    dest: undefined # absolute directory of destination design.js file
    templatesDirectory: 'components'
    configurationElement: 'script[type=ld-conf]'
    minify:
      collapseWhitespace: true
      removeComments: true
      removeCommentsFromCDATA: true
      removeCDATASectionsFromCDATA: true
  , config


module.exports = (options) ->
  options = defaultConfig(options)
  design = new Design(options)

  # Add design configuration file (with global settings)
  configFilePath = path.join(options.src, 'config.json')
  design.initConfigFile configFilePath, (err) ->
    return design.error(err) if err

    templatesPath = path.join(options.src, options.templatesDirectory)
    new Glob '**/*.html', cwd: templatesPath, (err, files) ->
      return design.error(err) if err

      if files?.length
        async.each files, (filepath, done) ->
          design.addTemplateFile(path.join(templatesPath, filepath), done)
        , (err) =>
          return design.error(err) if err
          design.emit('end')
          # design.save(options.dest + '/design.js', options.minify)

      else
        design.emit('warn', "The design '#{options.design}' has no templates")
        design.emit('end')

  design
