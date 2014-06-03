DockerCommander = require '../lib/controller'
utils = require '../middlewares/utils'

commander = new DockerCommander()
NotFound = ->
    err = new Error('This app doesn\'t exists')
    err.statusCode = 404
    return err

AppExists = ->
    err = new Error('This app doesn\'t exists')
    err.statusCode = 401
    return err

parseGitUrl = (url) ->
    split = url.split '/'

    gituser = split[3]
    gitname = split[4].split('.')[0]
    dockeruser = gituser.replace 'mycozycloud', 'cozy'
    dockername = gitname
    imagename = dockeruser + '/' + dockername
    slug = dockername.replace 'cozy-', ''

    return {slug, imagename}


ensureInstalled = (slug, app, cb) ->
    commander.exist slug, (err, docExist) ->
        return cb err if err
        if not docExist
            if slug in ['home', 'proxy', 'datasystem']
                app.password = utils.getToken()
            {imagename} = parseGitUrl app.repository.url
            commander.install imagename, 'latest', {}, cb
        else
            cb AppExists('This app already exists')

# post /drones/:slug/start
module.exports.start = (req, res, next) ->
    app = req.body.start
    name = app.name
    ensureInstalled name, app, (err) =>
        return next err if err?
        console.log "INSTALLED"
        switch name
            when 'data-system'
                commander.startDataSystem (err) ->
                    next err if err?
                    res.send 200, app
            when 'couchdb'
                commander.startCouch (err) ->
                    next err if err?
                    res.send 200, app
            when 'proxy'
                commander.startProxy (err, app) ->
                    next err if err?
                    res.send 200, app
            else
                env = "NAME=#{name} TOKEN=#{app.password}"
                {imagename} = parseGitUrl app.repository.url
                commander.startApplication imagename, env, (err, image, port) =>
                    next err if err?
                    app.port = port
                    res.send 200, drone: app

# post /drones/:slug/stop
module.exports.stop = (req, res, next) ->
    app = req.body.stop
    commander.exist app.name, (err, docExist) ->
        return next err if err
        if docExist
            commander.stop app.name, (err, image) ->
                next err if err?
                res.send 200, {}
        else
            res.send 200, {}

# post /drones/:slug/light-update
module.exports.update = (req, res, next) ->
    app = req.body.update
    commander.exist app.name, (err, docExist) ->
        return next err if err
        if docExist
            env = "NAME=#{app.name} TOKEN=#{app.password}"
            {imagename} = parseGitUrl app.repository.url
            commander.updateApplication imagename, env, (err, image, port) =>
                next err if err?
                app.port = port
                res.send 200, drone: app
        else
            next NotFound()

# post /drones/:slug/clean
module.exports.clean = (req, res, next) ->
    app = req.body
    commander.exist app.name, (err, docExist) ->
        return next err if err
        if docExist
            commander.uninstallApplication app.name, (err) ->
                next err if err?
                res.send 200, {}
        else
            res.send 200, {}

# get /drones/running
module.exports.running = (req, res, next) ->
    commander.running (err, result) ->
        return next err if err
        res.send 200, result

