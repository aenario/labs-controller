async = require 'async'
path = require 'path'
Client = require('request-json').JsonClient

DockerCommander = require '../server/lib/controller'

module.exports.commander = commander = new DockerCommander()
docker = commander.docker

helpers = {}
if process.env.USE_JS
    helpers.prefix = path.join __dirname, '../build/'
else
    helpers.prefix = path.join __dirname, '../'

# server management
helpers.options =
    serverHost: process.env.HOST or 'localhost'
    serverPort: process.env.PORT or 9121


module.exports.stopAllContainers = (done)->
    @timeout 10000
    docker.listContainers all: true, (err, containers) ->
        return done err if err
        async.forEach containers, (containerInfo, cb) ->
            commander.expectedStops[containerInfo.Id] = true
            docker.getContainer(containerInfo.Id).kill cb
        , done

module.exports.deleteAllContainers = (done)->
    @timeout 10000
    docker.listContainers all: true, (err, containers) ->
        return done err if err
        async.forEach containers, (containerInfo, cb) ->
            docker.getContainer(containerInfo.Id).remove cb
        , done

module.exports.deleteAllImages = (done) ->
    @timeout 10000
    docker.listImages (err, images) ->
        return done err if err
        async.forEach images, (imageInfo, cb) ->
            return cb null if imageInfo.RepoTags[0].split(':')[0] is 'ubuntu'
            docker.getImage(imageInfo.Id).stop cb
        , done

# default client
client = new Client "http://#{helpers.options.serverHost}:#{helpers.options.serverPort}/", jar: true

# Returns a client if url is given, default app client otherwise
module.exports.getClient = (url = null) ->
    if url?
        return new Client url, jar: true
    else
        return client

console.log(helpers.prefix)
initializeApplication = require "#{helpers.prefix}server"
console.log(initializeApplication)

module.exports.startApp = (done) ->
    @timeout 400000
    initializeApplication (app, server) =>
        console.log(app)
        @app = app
        @app.server = server
        done()

module.exports.stopApp = (done) ->
    @timeout 10000
    setTimeout =>
        @app.server.close done
    , 1000