async = require 'async'

DockerCommander = require '../server/lib/controller'

module.exports.commander = commander = new DockerCommander()
docker = commander.docker

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