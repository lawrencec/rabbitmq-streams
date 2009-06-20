"""
Interfaces for plugin components to use.
"""

import couchdb.client as couch
import amqplib.client_0_8 as amqp
import os
import sys

feedshub_log_xname = 'feedshub/log'
plugin_config_header = 'x-streams-plugin-config'

try:
    import json
except:
    import simplejson as json

def ensure_resource(resource):
    try:
        resource.head()
    except:
        resource.put(content={'id': resource.uri.rpartition('/')[2]})

def amqp_connection_from_config(hostspec):
    hostname = hostspec['host']
    port = str(hostspec['port'])
    host = ":".join([hostname, port])
    virt = hostspec['virtual_host']
    userid, password = hostspec['username'], hostspec['password']
    connection = amqp.Connection(host=host,
                                 userid=userid,
                                 password=password,
                                 virtual_host=virt)
    return connection

def publish_to_exchange(component, channel, exchange, routing_key=''):
    def p(msg, **headers):
        message = amqp.Message(body=msg, children=None, delivery_mode=2, **headers)
        # TODO: treat application_headers specially, and expect a content type
        try:
            channel.basic_publish(message, exchange=exchange, routing_key=routing_key)
        except:
            errMsg = str("Exception when trying to publish to exchange " +
                         exchange + " with routing key " + routing_key)
            component.error(errMsg)
    return p

def subscribe_to_queue(channel, queue, method):
    # no_ack: If this field is set the server does not expect
    # acknowledgements for messages.
    channel.basic_consume(queue=queue,
                          no_ack=False,
                          callback=lambda msg:
                              txifyPlugin(channel, method, msg))

def txifyPlugin(channel, method, msg):
    try:
        method(msg)
        channel.basic_ack(msg.delivery_info['delivery_tag'])
        channel.tx_commit()
    except Exception:
        channel.tx_rollback()

class Plugin(object):

    INPUTS = {}
    OUTPUTS = {}

    def __init__(self, config):
        msghostspec = config['messageserver']
        self.__conn = amqp_connection_from_config(msghostspec)
        self.__channel = self.__conn.channel()
        self.__channel.tx_select()

        self.__log = self.__conn.channel() # a new channel which isn't tx'd
        self.build_logger(config)
        
        self.__stateresource = couch.Resource(None, config['state'])
        ensure_resource(self.__stateresource)

        if 'database' in config and config['database'] is not None:
            self.__db = couch.Database(config['database'])
        else:
            self.__db = None
        settings = dict((item['name'], item['value'])
                        for item in config['plugin_type']['global_configuration_specification'])
        settings.update(config['configuration'])
        self._static_config = settings

        for name, exchange in config['outputs'].iteritems():
            if name not in self.OUTPUTS:
                self.OUTPUTS[name] = name
            setattr(self, self.OUTPUTS[name],
                    publish_to_exchange(self, self.__channel, exchange))

    # An annotation for making a handler take dynamic config as well
        def handler(fun):
            def handle(msg):
                if 'application_headers' in msg.properties:
                    headers = msg.properties['application_headers']
                    if headers and plugin_config_header in headers:
                        config = headers[plugin_config_header]
                        self.debug("Plugin config found: " + config)
                        dynamic = {}
                        dynamic.update(self._static_config)
                        try:
                            headerConfig = json.loads(config)
                            if not isinstance(headerConfig, dict):
                                raise "Not a dict"
                        except:
                            self.error("Could not use config: " + config + "; ignoring message")
                            return
                        dynamic.update(headerConfig)
                        return fun(msg, dynamic)
                return fun(msg, self._static_config)
            return handle

        for name, queue in config['inputs'].iteritems():
            if name not in self.INPUTS:
                self.INPUTS[name] = name
            method = getattr(self, self.INPUTS[name])
            subscribe_to_queue(self.__channel, queue, handler(method))

        self.info('Starting up...')

    def commit(self):
        self.__channel.tx_commit()

    def rollback(self):
        self.__channel.tx_rollback()

    def build_logger(self, config):
        feed_id = config['feed_id']
        node_id = config['node_id']
        plugin_name = config['plugin_name']
        for level in ['debug', 'info', 'warn', 'error', 'fatal']:
            rk = level + '.' + feed_id + '.' + plugin_name + '.' + node_id
            setattr(self, level, publish_to_exchange(self, self.__log, feedshub_log_xname,
                                                     routing_key = rk))

    def putState(self, state):
        """Record the state of the component"""
        #print "Putting state: "
        #print json.dumps(state)
        resp, data = self.__stateresource.put(content = state)
        return self.getState()

    def getState(self, defaultState = None):
        try:
            resp, data = self.__stateresource.get()
            return couch.Document(data)
        except couch.ResourceNotFound:
            return defaultState

    def privateDatabase(self):
        return self.__db

    def run(self):
        while True:
            self.__channel.wait()

    def start(self):
        self.run()
