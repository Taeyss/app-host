FROM ruby:2.5.1

ENV RAILS_ENV production

RUN echo "deb http://archive.debian.org/debian stretch main" > /etc/apt/sources.list \
    && echo "deb http://archive.debian.org/debian-security stretch/updates main" >> /etc/apt/sources.list \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends --allow-unauthenticated \
        imagemagick \
        libsqlite3-dev \
        nginx \
        nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN gem sources --add https://gems.ruby-china.com --remove https://rubygems.org/

RUN gem install bundler -v 2.3.27

WORKDIR /app

ADD Gemfile* ./
RUN bundle install
COPY . .
COPY docker/nginx.conf /etc/nginx/sites-enabled/app.conf

# 编译静态文件
RUN rake assets:precompile

EXPOSE 8686

CMD /bin/bash docker/check_prereqs.sh && service nginx start && puma -C config/puma.rb
