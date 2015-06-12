_ = require 'underscore'
{BufferedProcess} = require 'nylas-exports'
Q = require 'q'
semver = require 'semver'

module.exports =
class APMWrapper

  constructor: ->
    @packagePromises = []

  runCommand: (args, callback) ->
    command = atom.packages.getApmPath()
    outputLines = []
    stdout = (lines) -> outputLines.push(lines)
    errorLines = []
    stderr = (lines) -> errorLines.push(lines)
    exit = (code) ->
      callback(code, outputLines.join('\n'), errorLines.join('\n'))
    options =
      env:
        ATOM_API_URL: 'https://edgehill-packages.nylas.com/api'
        ATOM_HOME: atom.getConfigDirPath()

    args.push('--no-color')
    new BufferedProcess({command, args, stdout, stderr, exit, options})

  runCommandReturningPackages: (args, errorMessage, callback) ->
    @runCommand args, (code, stdout, stderr) ->
      if code is 0
        try
          packages = JSON.parse(stdout) ? []
        catch parseError
          error = createJsonParseError(errorMessage, parseError, stdout)
          return callback(error)
        callback(null, packages)
      else
        error = new Error(errorMessage)
        error.stdout = stdout
        error.stderr = stderr
        callback(error)

  loadInstalled: (callback) ->
    args = ['ls', '--json']
    errorMessage = 'Fetching local packages failed.'
    apmProcess = @runCommandReturningPackages(args, errorMessage, callback)

    handleProcessErrors(apmProcess, errorMessage, callback)

  loadFeatured: (options, callback) ->
    args = ['featured', '--json']
    version = atom.getVersion()
    args.push('--themes') if options.themes
    args.push('--compatible', version) if semver.valid(version)
    errorMessage = 'Fetching featured packages failed.'

    apmProcess = @runCommandReturningPackages(args, errorMessage, callback)
    handleProcessErrors(apmProcess, errorMessage, callback)

  loadOutdated: (callback) ->
    args = ['outdated', '--json']
    version = atom.getVersion()
    args.push('--compatible', version) if semver.valid(version)
    errorMessage = 'Fetching outdated packages and themes failed.'

    apmProcess = @runCommandReturningPackages(args, errorMessage, callback)
    handleProcessErrors(apmProcess, errorMessage, callback)

  loadPackage: (packageName, callback) ->
    args = ['view', packageName, '--json']
    errorMessage = "Fetching package '#{packageName}' failed."

    apmProcess = @runCommandReturningPackages(args, errorMessage, callback)
    handleProcessErrors(apmProcess, errorMessage, callback)

  loadCompatiblePackageVersion: (packageName, callback) ->
    args = ['view', packageName, '--json', '--compatible', @normalizeVersion(atom.getVersion())]
    errorMessage = "Fetching package '#{packageName}' failed."

    apmProcess = @runCommandReturningPackages(args, errorMessage, callback)
    handleProcessErrors(apmProcess, errorMessage, callback)

  getInstalled: ->
    Promise.promisify(@loadInstalled, this)()

  getFeatured: (options = {}) ->
    Promise.promisify(@loadFeatured, this)(options)

  getOutdated: ->
    Promise.promisify(@loadOutdated, this)()

  getPackage: (packageName) ->
    @packagePromises[packageName] ?= Promise.promisify(@loadPackage, this, packageName)()

  satisfiesVersion: (version, metadata) ->
    engine = metadata.engines?.atom ? '*'
    return false unless semver.validRange(engine)
    return semver.satisfies(version, engine)

  normalizeVersion: (version) ->
    [version] = version.split('-') if typeof version is 'string'
    version

  search: (query, options = {}) ->
    deferred = Promise.defer()

    args = ['search', query, '--json']
    if options.themes
      args.push '--themes'
    else if options.packages
      args.push '--packages'
    errorMessage = "Searching for \u201C#{query}\u201D failed."

    apmProcess = @runCommand args, (code, stdout, stderr) ->
      if code is 0
        try
          packages = JSON.parse(stdout) ? []
          deferred.resolve(packages)
        catch parseError
          error = createJsonParseError(errorMessage, parseError, stdout)
          deferred.reject(error)
      else
        error = new Error(errorMessage)
        error.stdout = stdout
        error.stderr = stderr
        deferred.reject(error)

    handleProcessErrors apmProcess, errorMessage, (error) ->
      deferred.reject(error)

    deferred.promise

  update: (pack, newVersion, callback) ->
    {name, theme} = pack

    if theme
      activateOnSuccess = atom.packages.isPackageActive(name)
    else
      activateOnSuccess = not atom.packages.isPackageDisabled(name)
    activateOnFailure = atom.packages.isPackageActive(name)
    atom.packages.deactivatePackage(name) if atom.packages.isPackageActive(name)
    atom.packages.unloadPackage(name) if atom.packages.isPackageLoaded(name)

    errorMessage = "Updating to \u201C#{name}@#{newVersion}\u201D failed."
    onError = (error) =>
      error.packageInstallError = not theme
      callback(error)

    args = ['install', "#{name}@#{newVersion}"]
    exit = (code, stdout, stderr) =>
      if code is 0
        if activateOnSuccess
          atom.packages.activatePackage(name)
        else
          atom.packages.loadPackage(name)

        callback?()
      else
        atom.packages.activatePackage(name) if activateOnFailure
        error = new Error(errorMessage)
        error.stdout = stdout
        error.stderr = stderr
        onError(error)

    apmProcess = @runCommand(args, exit)
    handleProcessErrors(apmProcess, errorMessage, onError)

  unload: (packageName) ->
    if atom.packages.isPackageLoaded(name)
      atom.packages.deactivatePackage(name) if atom.packages.isPackageActive(name)
      atom.packages.unloadPackage(name)

  install: (pack, callback) ->
    {name, version, theme} = pack
    activateOnSuccess = not theme and not atom.packages.isPackageDisabled(name)
    activateOnFailure = atom.packages.isPackageActive(name)

    @unload(name)
    args = ['install', "#{name}@#{version}"]

    errorMessage = "Installing \u201C#{name}@#{version}\u201D failed."
    onError = (error) =>
      error.packageInstallError = not theme
      callback(error)

    exit = (code, stdout, stderr) =>
      if code is 0
        if activateOnSuccess
          atom.packages.activatePackage(name)
        else
          atom.packages.loadPackage(name)

        callback?()
      else
        atom.packages.activatePackage(name) if activateOnFailure
        error = new Error(errorMessage)
        error.stdout = stdout
        error.stderr = stderr
        onError(error)

    apmProcess = @runCommand(args, exit)
    handleProcessErrors(apmProcess, errorMessage, onError)

  uninstall: (pack, callback) ->
    {name} = pack

    atom.packages.deactivatePackage(name) if atom.packages.isPackageActive(name)

    errorMessage = "Uninstalling \u201C#{name}\u201D failed."
    onError = (error) =>
      callback(error)

    apmProcess = @runCommand ['uninstall', '--hard', name], (code, stdout, stderr) =>
      if code is 0
        @unload(name)
        callback?()
      else
        error = new Error(errorMessage)
        error.stdout = stdout
        error.stderr = stderr
        onError(error)

    handleProcessErrors(apmProcess, errorMessage, onError)

  canUpgrade: (installedPackage, availableVersion) ->
    return false unless installedPackage?

    installedVersion = installedPackage.metadata.version
    return false unless semver.valid(installedVersion)
    return false unless semver.valid(availableVersion)

    semver.gt(availableVersion, installedVersion)

  checkNativeBuildTools: ->
    deferred = Promise.defer()
    apmProcess = @runCommand ['install', '--check'], (code, stdout, stderr) ->
      if code is 0
        deferred.resolve()
      else
        deferred.reject(new Error())

    apmProcess.onWillThrowError ({error, handle}) ->
      handle()
      deferred.reject(error)

    deferred.promise

createJsonParseError = (message, parseError, stdout) ->
  error = new Error(message)
  error.stdout = ''
  error.stderr = "#{parseError.message}: #{stdout}"
  error

createProcessError = (message, processError) ->
  error = new Error(message)
  error.stdout = ''
  error.stderr = processError.message
  error

handleProcessErrors = (apmProcess, message, callback) ->
  apmProcess.onWillThrowError ({error, handle}) ->
    handle()
    callback(createProcessError(message, error))