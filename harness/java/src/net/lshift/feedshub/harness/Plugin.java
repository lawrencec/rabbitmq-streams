package net.lshift.feedshub.harness;

import java.io.IOException;
import java.lang.reflect.Field;

import net.sf.json.JSONArray;
import net.sf.json.JSONObject;

import com.rabbitmq.client.Channel;
import com.rabbitmq.client.Connection;
import com.rabbitmq.client.Consumer;
import com.rabbitmq.client.Envelope;
import com.rabbitmq.client.ShutdownSignalException;
import com.rabbitmq.client.AMQP.BasicProperties;

public abstract class Plugin {

	final protected Connection messageServerConnection;
	final protected Channel messageServerChannel;
	final protected JSONObject config;
	final protected JSONObject configuration;

	protected Plugin(final JSONObject config) throws IOException {
		this.config = config;
		this.configuration = config.getJSONObject("config").getJSONObject(
				"configuration");
		JSONObject messageServerSpec = config.getJSONObject("messageserver");
		messageServerConnection = AMQPConnection
				.amqConnectionFromConfig(messageServerSpec);
		messageServerChannel = messageServerConnection.createChannel();
	}

	protected void init() throws Exception {
		JSONObject pluginType = config.getJSONObject("plugin_type");

		JSONArray inputsAry = config.getJSONArray("inputs");
		JSONArray inputTypesAry = pluginType.getJSONArray("inputs");

		for (int idx = 0; idx < inputsAry.size() && idx < inputTypesAry.size(); ++idx) {
			final String fieldName = inputTypesAry.getJSONObject(idx)
					.getString("name");
			Consumer callback = new Consumer() {

				private final Field pluginQueueField = Plugin.this.getClass()
						.getField(fieldName);

				public void handleCancelOk(String consumerTag) {
					try {
						Object consumer = pluginQueueField.get(Plugin.this);
						((Consumer) consumer).handleCancelOk(consumerTag);
					} catch (IllegalArgumentException e) {
						e.printStackTrace();
						System.exit(1);
					} catch (IllegalAccessException e) {
						e.printStackTrace();
						System.exit(1);
					}
				}

				public void handleConsumeOk(String consumerTag) {
					try {
						Object consumer = pluginQueueField.get(Plugin.this);
						((Consumer) consumer).handleConsumeOk(consumerTag);
					} catch (IllegalArgumentException e) {
						e.printStackTrace();
						System.exit(1);
					} catch (IllegalAccessException e) {
						e.printStackTrace();
						System.exit(1);
					}
				}

				public void handleDelivery(String arg0, Envelope arg1,
						BasicProperties arg2, byte[] arg3) throws IOException {
					try {
						Object consumer = pluginQueueField.get(Plugin.this);
						((Consumer) consumer).handleDelivery(arg0, arg1, arg2,
								arg3);
					} catch (IllegalArgumentException e) {
						e.printStackTrace();
						System.exit(1);
					} catch (IllegalAccessException e) {
						e.printStackTrace();
						System.exit(1);
					}
				}

				public void handleShutdownSignal(String consumerTag,
						ShutdownSignalException sig) {
					try {
						Object consumer = pluginQueueField.get(Plugin.this);
						((Consumer) consumer).handleShutdownSignal(consumerTag,
								sig);
					} catch (IllegalArgumentException e) {
						e.printStackTrace();
						System.exit(1);
					} catch (IllegalAccessException e) {
						e.printStackTrace();
						System.exit(1);
					}
				}

			};
			messageServerChannel.basicConsume(inputsAry.getString(idx), true,
					callback);
		}

		JSONArray outputsAry = config.getJSONArray("outputs");
		JSONArray outputTypesAry = pluginType.getJSONArray("outputs");

		final BasicProperties blankBasicProps = new BasicProperties();
		blankBasicProps.deliveryMode = 2; // persistent
		for (int idx = 0; idx < outputsAry.size()
				&& idx < outputTypesAry.size(); ++idx) {
			final String exchange = outputsAry.getString(idx);
			final Publisher publisher = new Publisher() {

				public void publish(byte[] body) throws IOException {
					messageServerChannel.basicPublish(exchange, "",
							blankBasicProps, body);
				}

				public void acknowledge(long deliveryTag) throws IOException {
					messageServerChannel.basicAck(deliveryTag, false);
				}
			};
			Field outputField = Plugin.this.getClass().getField(
					outputTypesAry.getJSONObject(idx).getString("name"));
			outputField.set(Plugin.this, publisher);
		}
	}

	public void shutdown() throws IOException {
		messageServerChannel.close();
		messageServerConnection.close();
	}

	public abstract void run() throws IOException;

}