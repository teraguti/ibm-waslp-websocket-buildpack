# Encoding: utf-8
# Cloud Foundry Java Buildpack
# IBM WebSphere Application Server Liberty Buildpack
# Copyright 2013-2014 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'spec_helper'
require 'application_helper'
require 'buildpack_cache_helper'
require 'internet_availability_helper'
require 'logging_helper'
require 'fileutils'
require 'constants'
require 'liberty_buildpack/util/cache/download_cache'
require 'liberty_buildpack/util/cache/internet_availability'

describe LibertyBuildpack::Util::Cache::DownloadCache do
  include_context 'application_helper'
  include_context 'internet_availability_helper'
  include_context 'logging_helper'

  let(:default_user_agent) { Constants::DEFAULT_USER_AGENT }
  let(:default_user_agent_base) { Constants::DEFAULT_USER_AGENT_BASE }

  let(:download_cache) { described_class.new(app_dir) }

  let(:trigger) { download_cache.get('http://foo-uri/') {} }

  it 'should download (during internet availability checking) from a uri if the cached file does not exist' do
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    trigger

    expect_complete_cache
  end

  it 'should set a User-Agent header for a GET' do
    stub_request(:any, 'http://foo-uri/')

    trigger

    a_request(:get, 'http://foo-uri/')
      .with('headers' => { 'Accept' => '*/*', 'User-Agent' => default_user_agent })
      .should have_been_made
  end

  it 'should use the User-Agent environment variable when given' do
    ENV['USER_AGENT'] = 'test'
    stub_request(:any, 'http://foo-uri/')

    trigger

    ENV.delete('USER_AGENT')

    a_request(:get, 'http://foo-uri/')
      .with('headers' => { 'Accept' => '*/*', 'User-Agent' => default_user_agent_base + '-test' })
      .should have_been_made
  end

  it 'should download (after internet availability checking) from a uri if the cached file does not exist',
     :skip_availability_check do

    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    download_cache.get('http://foo-uri/') {}

    expect_complete_cache
  end

  it 'should deliver cached data',
     :skip_availability_check do

    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    download_cache.get('http://foo-uri/') do |data_file|
      expect(data_file.read).to eq('foo-cached')
    end
  end

  it 'should not perform update check if etag is missing' do
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { 'Last-Modified' => 'foo-last-modified' })

    download_cache.get('http://foo-uri/') do |data_file|
      expect(data_file.read).to eq('foo-cached')
    end

  end

  it 'should not perform update check if last-modified is missing' do
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag' })

    download_cache.get('http://foo-uri/') do |data_file|
      expect(data_file.read).to eq('foo-cached')
    end

  end

  it 'should not raise error if download cannot be completed but retrying succeeds' do
    stub_request(:get, 'http://foo-uri/').to_raise(SocketError).then
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    trigger

    expect_complete_cache
  end

  it 'should not raise error if download succeeds and HEAD request cannot be completed but retrying succeeds' do
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_raise(SocketError).then
    .to_return(status: 304, body: '', headers: {})

    trigger

    expect_complete_cache
  end

  it 'should use cached copy if HEAD fails',
     :skip_availability_check do
    stub_request(:head, 'http://foo-uri/').to_raise(SocketError)

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'

    trigger
  end

  it 'should check using HEAD if the cached file exists and etag exists',
     :skip_availability_check do

    stub_request(:head, 'http://foo-uri/').with(headers: { 'If-None-Match' => 'foo-etag' })
    .to_return(status: 304, body: 'foo-cached', headers: {})

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'

    trigger

    expect_file_content 'cached', 'foo-cached'
    expect_file_content 'etag', 'foo-etag'
  end

  it 'should check using HEAD if the cached file exists and last modified exists',
     :skip_availability_check do

    stub_request(:head, 'http://foo-uri/').with(headers: { 'If-Modified-Since' => 'foo-last-modified' })
    .to_return(status: 304, body: 'foo-cached', headers: {})

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_file_content 'cached', 'foo-cached'
    expect_file_content 'last_modified', 'foo-last-modified'
  end

  it 'should check using HEAD if the cached file exists, etag exists, and last modified exists' do
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'If-None-Match' => 'foo-etag', 'If-Modified-Since' => 'foo-last-modified' })
    .to_return(status: 304, body: 'foo-cached', headers: {})

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_complete_cache
  end

  it 'should download from a uri if the cached file does not exist, etag exists, and last modified exists' do
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_complete_cache
  end

  it 'should not download from a uri if the cached file exists and the etag and last modified do not exist' do
    touch app_dir, 'cached', 'foo-cached'

    trigger

    expect_file_content 'cached', 'foo-cached'
  end

  it 'should not overwrite existing information if 304 is received' do
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'If-None-Match' => 'foo-etag', 'If-Modified-Since' => 'foo-last-modified' })
    .to_return(status: 304, body: '', headers: {})

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_complete_cache
  end

  it 'should use the cache if HEAD returns a bad HTTP response' do
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'If-None-Match' => 'foo-etag', 'If-Modified-Since' => 'foo-last-modified' })
    .to_return(status: 500, body: '', headers: {})

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect(stderr.string).to match('Unable to check whether or not http://foo-uri/ has been modified due to Bad HTTP response: 500')
    expect_complete_cache
  end

  it 'should overwrite existing information if 304 is not received',
     :skip_availability_check do

    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 200, body: '', headers: {})
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'bar-cached', headers: { Etag: 'bar-etag', 'Last-Modified' => 'bar-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'bar-last-modified', 'If-None-Match' => 'bar-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_file_content 'cached', 'bar-cached'
    expect_file_content 'etag', 'bar-etag'
    expect_file_content 'last_modified', 'bar-last-modified'
  end

  it 'should not overwrite existing information if the update request fails',
     :skip_availability_check do

    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 200, body: '', headers: {})
    stub_request(:get, 'http://foo-uri/')
    .to_raise(SocketError)

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_complete_cache

    expect(stderr.string).to match('HTTP request failed:')
  end

  it 'should not overwrite existing information if the HEAD request fails',
     :skip_availability_check do

    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_raise(SocketError)

    touch app_dir, 'cached', 'foo-cached'
    touch app_dir, 'etag', 'foo-etag'
    touch app_dir, 'last_modified', 'foo-last-modified'

    trigger

    expect_complete_cache

    expect(stderr.string).to match('Unable to check whether or not http://foo-uri/ has been modified due to Exception from WebMock. Using cached version.')
  end

  it 'should pass read-only file to block' do
    stub_request(:get, 'http://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'http://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    download_cache.get('http://foo-uri/') do |file|
      expect(file.read).to eq('foo-cached')
      expect { file.write('bar') }.to raise_error(IOError, 'not opened for writing')
    end
  end

  it 'should delete the cached file if it exists' do
    expect_file_deleted 'cached'
  end

  it 'should delete the etag file if it exists' do
    expect_file_deleted 'etag'
  end

  it 'should delete the last_modified file if it exists' do
    expect_file_deleted 'last_modified'
  end

  it 'should delete the lock file if it exists' do
    expect_file_deleted 'lock'
  end

  context do
    include_context 'buildpack_cache_helper'

    it 'should use the buildpack cache if the download cannot be completed' do
      stub_request(:get, 'http://foo-uri/').to_raise(SocketError)

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-stashed')
      end
    end

    it 'should use the buildpack cache if start request fails' do
      begin
        # Make sure 'start' method is not an empty code.
        WebMock.allow_net_connect!(net_http_connect_on_start: true)
        # Mock it into raising an exception
        Net::HTTP.stub(:start).and_raise(SocketError)

        touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

        download_cache.get('http://foo-uri/') do |file|
          expect(file.read).to eq('foo-stashed')
        end
      ensure
        # Reset both Net:HTTP and net_http_connect_on_start to default values
        RSpec::Mocks.space.proxy_for(Net::HTTP).reset
        WebMock.allow_net_connect!(net_http_connect_on_start: false)
      end
    end

    it 'should not use the buildpack cache if the download cannot be completed but a retry succeeds' do
      stub_request(:get, 'http://foo-uri/').to_raise(SocketError).then
      .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
      stub_request(:head, 'http://foo-uri/')
      .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
      .to_return(status: 304, body: '', headers: {})

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-cached')
      end
    end

    it 'should not use the buildpack cache if the download succeeds and the HEAD request cannot be completed but a retry succeeds' do
      stub_request(:get, 'http://foo-uri/')
      .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
      stub_request(:head, 'http://foo-uri/')
      .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
      .to_raise(SocketError).then
      .to_return(status: 304, body: '', headers: {})

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-cached')
      end
    end

    it 'should use the buildpack cache if the download cannot be completed because Errno::ENETUNREACH is raised', :skip_availability_check do
      stub_request(:get, 'http://foo-uri/').to_raise(Errno::ENETUNREACH)

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-stashed')
      end

      expect(stderr.string).to match('Network is unreachable')
    end

    it 'should use the buildpack cache if the download is truncated' do
      stub_request(:head, 'http://foo-uri/')
      .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
      .to_return(status: 200, body: '', headers: {})
      stub_request(:get, 'http://foo-uri/')
      .to_return(status: 200, body: 'foo-cac', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified', 'Content-Length' => 10 })

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-stashed')
      end
    end

    it 'should use the buildpack cache if download returns 304' do
      stub_request(:get, 'http://foo-uri/')
      .to_return(status: 304, body: '', headers: {})

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-stashed')
      end
    end

    it 'should use the buildpack cache if the cache configuration disables remote downloads' do
      expect(LibertyBuildpack::Util::Cache::InternetAvailability).to receive(:use_internet?).at_least(:once).and_return(false)

      touch java_buildpack_cache_dir, 'cached', 'foo-stashed'

      download_cache.get('http://foo-uri/') do |file|
        expect(file.read).to eq('foo-stashed')
      end
    end

    it 'should raise error if download cannot be completed and buildpack cache does not contain the file' do
      stub_request(:get, 'http://foo-uri/').to_raise(SocketError)

      expect { trigger }.to raise_error %r(Buildpack cache does not contain http://foo-uri/)
    end

    it 'should raise error if a download attempt fails', :skip_availability_check do
      stub_request(:get, 'http://bar-uri/').to_raise(SocketError)
      expect { download_cache.get('http://bar-uri/') {} }.to raise_error %r(Buildpack cache does not contain http://bar-uri/)
    end
  end

  it 'should fail if a download attempt fails and there is no buildpack cache', :skip_availability_check do
    stub_request(:get, 'http://bar-uri/').to_raise(SocketError)
    expect { download_cache.get('http://bar-uri/') {} }.to raise_error /Buildpack cache not defined/
  end

  it 'should support https downloads',
     :skip_availability_check do

    stub_request(:get, 'https://foo-uri/')
    .to_return(status: 200, body: 'foo-cached', headers: { Etag: 'foo-etag', 'Last-Modified' => 'foo-last-modified' })
    stub_request(:head, 'https://foo-uri/')
    .with(headers: { 'Accept' => '*/*', 'If-Modified-Since' => 'foo-last-modified', 'If-None-Match' => 'foo-etag', 'User-Agent' => default_user_agent })
    .to_return(status: 304, body: '', headers: {})

    download_cache.get('https://foo-uri/') {}
  end

  def cache_file(root, extension)
    root + "http:%2F%2Ffoo-uri%2F.#{extension}"
  end

  def expect_complete_cache
    expect_file_content 'cached', 'foo-cached'
    expect_file_content 'etag', 'foo-etag'
    expect_file_content 'last_modified', 'foo-last-modified'
  end

  def expect_file_content(extension, content = '')
    file = cache_file app_dir, extension
    expect(file).to exist
    expect(file.read).to eq(content)
  end

  def expect_file_deleted(extension)
    file = touch app_dir, extension
    expect(file).to exist

    download_cache.evict('http://foo-uri/')

    expect(file).not_to exist
  end

  def touch(root, extension, content = '')
    file = cache_file root, extension
    FileUtils.mkdir_p file.dirname
    file.open('w') { |f| f.write(content) }

    file
  end

end
