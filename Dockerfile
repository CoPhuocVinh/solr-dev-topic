# Solr 7.7.3 with ICU analysis-extras (ICUTokenizerFactory) for Vietnamese text
# JARs go in WEB-INF/lib so they are on the JVM classpath when Solr starts
FROM alpine:3.18 AS fetcher
RUN apk add --no-cache wget && \
  wget -q -O /tmp/solr.tgz https://archive.apache.org/dist/lucene/solr/7.7.3/solr-7.7.3.tgz && \
  tar xzf /tmp/solr.tgz -C /tmp

FROM solr:7.7.3
USER root
COPY --from=fetcher /tmp/solr-7.7.3/contrib/analysis-extras/lib/*.jar /opt/solr/server/solr-webapp/webapp/WEB-INF/lib/
COPY --from=fetcher /tmp/solr-7.7.3/dist/solr-analysis-extras-7.7.3.jar /opt/solr/server/solr-webapp/webapp/WEB-INF/lib/
RUN chown -R solr:solr /opt/solr/server/solr-webapp/webapp/WEB-INF/lib/
USER solr
