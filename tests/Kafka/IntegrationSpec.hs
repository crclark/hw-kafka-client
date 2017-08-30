{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Kafka.IntegrationSpec
( spec
) where

import           Control.Exception
import           Control.Monad       (forM_)
import           Control.Monad.Loops
import qualified Data.ByteString     as BS
import           Data.Either
import           Data.Monoid         ((<>))
import           System.Environment

import Kafka.Consumer as C
import Kafka.Metadata as M
import Kafka.Producer as P

import Test.Hspec

brokerAddress :: IO BrokerAddress
brokerAddress = BrokerAddress <$> getEnv "KAFKA_TEST_BROKER" `catch` \(_ :: SomeException) -> (return "localhost:9092")

testTopic :: IO TopicName
testTopic = TopicName <$> getEnv "KAFKA_TEST_TOPIC" `catch` \(_ :: SomeException) -> (return "kafka-client_tests")

testGroupId :: ConsumerGroupId
testGroupId = ConsumerGroupId "it_spec_03"

consumerProps :: BrokerAddress -> ConsumerProperties
consumerProps broker = C.brokersList [broker]
                    <> groupId testGroupId
                    <> C.setCallback (logCallback (\l s1 s2 -> print $ show l <> ": " <> s1 <> ", " <> s2))
                    <> C.setCallback (errorCallback (\e r -> print $ show e <> ": " <> r))
                    <> noAutoCommit

producerProps :: BrokerAddress -> ProducerProperties
producerProps broker = P.brokersList [broker]
                    <> P.setCallback (logCallback (\l s1 s2 -> print $ show l <> ": " <> s1 <> ", " <> s2))
                    <> P.setCallback (errorCallback (\e r -> print $ show e <> ": " <> r))

testSubscription :: TopicName -> Subscription
testSubscription t = topics [t]
              <> offsetReset Earliest

spec :: Spec
spec = describe "Kafka.IntegrationSpec" $ do
    it "sends messages to test topic" $ do
        broker <- brokerAddress
        topic  <- testTopic
        let msgs = testMessages topic
        res    <- runProducer (producerProps broker) (sendMessages msgs)
        res `shouldBe` Right ()

    it "consumes messages from test topic" $ do
        broker <- brokerAddress
        topic  <- testTopic
        res    <- runConsumer
                    (consumerProps broker)
                    (testSubscription topic)
                    (\k -> do
                        msgs <- receiveMessages k

                        wOffsets <- watermarkOffsets k (Timeout 1000) topic
                        length wOffsets `shouldBe` 1
                        forM_ wOffsets (`shouldSatisfy` isRight)

                        sub  <- subscription k
                        sub `shouldSatisfy` isRight
                        length <$> sub `shouldBe` Right 1

                        {-  Somehow this fails with "Assertion failed: (r == 0), function rwlock_wrlock, file tinycthread.c, line 1011." -}
                        asgm <- assignment k
                        asgm `shouldSatisfy` isRight
                        length <$> asgm `shouldBe` Right 1

                        -- {-  Real all topics metadata -}
                        allMeta <- allTopicsMetadata k (Timeout 1000)
                        allMeta `shouldSatisfy` isRight
                        (length . kmBrokers) <$> allMeta `shouldBe` Right 1
                        (length . kmTopics) <$> allMeta `shouldBe` Right 2

                        -- {- Read specific topic metadata -}
                        tMeta <- topicMetadata k (Timeout 1000) topic
                        tMeta `shouldSatisfy` isRight
                        (length . kmBrokers) <$> tMeta `shouldBe` Right 1
                        (length . kmTopics) <$> tMeta `shouldBe` Right 1

                        -- {- Describe all consumer grops -}
                        allGroups <- allConsumerGroupsInfo k (Timeout 1000)
                        fmap giGroup <$> allGroups `shouldBe` Right [testGroupId]

                        -- {- Describe specific consumer grops -}
                        grp <- consumerGroupInfo k (Timeout 1000) testGroupId
                        fmap giGroup <$> grp `shouldBe` Right [testGroupId]

                        noGroup <- consumerGroupInfo k (Timeout 1000) (ConsumerGroupId "does-not-exist")
                        noGroup `shouldBe` Right []

                        ots <- topicOffsetsForTime k (Timeout 1000) (Millis 1904057189508) topic
                        ots `shouldSatisfy` isRight
                        fmap tpOffset <$> ots `shouldBe` Right [PartitionOffsetEnd]

                        return msgs
                    )

        length <$> res `shouldBe` Right 2

        let timestamps = crTimestamp <$> either (const []) id res
        forM_ timestamps $ \ts ->
            ts `shouldNotBe` NoTimestamp

    it "Integration spec is finished" $ True `shouldBe` True

----------------------------------------------------------------------------------------------------------------

receiveMessages :: KafkaConsumer -> IO (Either a [ConsumerRecord (Maybe BS.ByteString) (Maybe BS.ByteString)])
receiveMessages kafka =
     (Right . rights) <$> www
     where
         www = whileJust maybeMsg return
         isOK msg = if msg /= Left (KafkaResponseError RdKafkaRespErrPartitionEof) then Just msg else Nothing
         maybeMsg = isOK <$> get
         get = pollMessage kafka (Timeout 1000)

testMessages :: TopicName -> [ProducerRecord]
testMessages t =
    [ ProducerRecord t UnassignedPartition Nothing (Just "test from producer")
    , ProducerRecord t UnassignedPartition (Just "key") (Just "test from producer (with key)")
    ]

sendMessages :: [ProducerRecord] -> KafkaProducer -> IO (Either KafkaError ())
sendMessages msgs prod =
  Right <$> forM_ msgs (produceMessage prod)
